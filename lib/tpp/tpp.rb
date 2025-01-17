require 'json'
require 'date'
require 'base64'
require 'utils/utils'

class Vcert::TPPConnection
  def initialize(url, user, password, trust_bundle: nil)
    @url = normalize_url url
    @user = user
    @password = password
    @token = nil
    @trust_bundle = trust_bundle
  end

  def request(zone_tag, request)
    data = {:PolicyDN => policy_dn(zone_tag),
            :PKCS10 => request.csr,
            :ObjectName => request.friendly_name,
            :DisableAutomaticRenewal => "true"}
    code, response = post URL_CERTIFICATE_REQUESTS, data
    if code != 200
      raise Vcert::ServerUnexpectedBehaviorError, "Status  #{code}"
    end
    request.id = response['CertificateDN']
  end

  def retrieve(request)
    retrieve_request = {CertificateDN: request.id, Format: "base64", IncludeChain: 'true', RootFirstOrder: "false"}
    code, response = post URL_CERTIFICATE_RETRIEVE, retrieve_request
    if code != 200
      return nil
    end
    full_chain = Base64.decode64(response['CertificateData'])
    cert = parse_full_chain full_chain
    if cert.private_key == nil
      cert.private_key = request.private_key
    end
    cert
  end

  def policy(zone_tag)
    code, response = post URL_ZONE_CONFIG, {:PolicyDN => policy_dn(zone_tag)}
    if code != 200
      raise Vcert::ServerUnexpectedBehaviorError, "Status  #{code}"
    end
    parse_policy_response response, zone_tag
  end

  def zone_configuration(zone_tag)
    code, response = post URL_ZONE_CONFIG, {:PolicyDN => policy_dn(zone_tag)}
    if code != 200
      raise Vcert::ServerUnexpectedBehaviorError, "Status  #{code}"
    end
    parse_zone_configuration response
  end

  def renew(request, generate_new_key: true)
    if request.id.nil? && request.thumbprint.nil?
      raise('Either request ID or certificate thumbprint is required to renew the certificate')
    end

    request.id = search_by_thumbprint(request.thumbprint) unless request.thumbprint.nil?
    renew_req_data = {"CertificateDN": request.id}
    if generate_new_key
      csr_base64_data = retrieve request
      LOG.info("Retrieved certificate:\n#{csr_base64_data.cert}")
      parsed_csr = parse_csr_fields_tpp(csr_base64_data.cert)
      renew_request = Vcert::Request.new(
        common_name: parsed_csr.fetch(:CN, nil),
        san_dns: parsed_csr.fetch(:DNS, nil),
        country: parsed_csr.fetch(:C, nil),
        province: parsed_csr.fetch(:ST, nil),
        locality: parsed_csr.fetch(:L, nil),
        organization: parsed_csr.fetch(:O, nil),
        organizational_unit: parsed_csr.fetch(:OU, nil)
      )
      renew_req_data.merge!(PKCS10: renew_request.csr)
    end
    LOG.info("Trying to renew certificate #{request.id}")
    _, d = post(URL_CERTIFICATE_RENEW, renew_req_data)
    raise 'Certificate renew error' unless d.key?('Success')

    if generate_new_key
      [request.id, renew_request.private_key]
    else
      [request.id, nil]
    end
  end

  private

  URL_AUTHORIZE = "authorize/"
  URL_CERTIFICATE_REQUESTS = "certificates/request"
  URL_ZONE_CONFIG = "certificates/checkpolicy"
  URL_CERTIFICATE_RETRIEVE = "certificates/retrieve"
  URL_CERTIFICATE_SEARCH = "certificates/"
  URL_CERTIFICATE_RENEW = "certificates/renew"
  URL_SECRET_STORE_SEARCH = "SecretStore/LookupByOwner"
  URL_SECRET_STORE_RETRIEVE = "SecretStore/Retrieve"

  TOKEN_HEADER_NAME = "x-venafi-api-key"
  ALL_ALLOWED_REGEX = ".*"

  def auth
    uri = URI.parse(@url)
    request = Net::HTTP.new(uri.host, uri.port)
    request.use_ssl = true
    if @trust_bundle != nil
      request.ca_file = @trust_bundle
    end
    url = uri.path + URL_AUTHORIZE
    data = {:Username => @user, :Password => @password}
    encoded_data = JSON.generate(data)
    response = request.post(url, encoded_data, {"Content-Type" => "application/json"})
    if response.code.to_i != 200
      raise Vcert::AuthenticationError
    end
    data = JSON.parse(response.body)
    token = data['APIKey']
    valid_until = DateTime.strptime(data['ValidUntil'].gsub(/\D/, ''), '%Q')
    @token = token, valid_until
  end

  def post(url, data)
    if @token == nil || @token[1] < DateTime.now
      auth()
    end
    uri = URI.parse(@url)
    request = Net::HTTP.new(uri.host, uri.port)
    request.use_ssl = true
    if @trust_bundle != nil
      request.ca_file = @trust_bundle
    end
    url = uri.path + url
    encoded_data = JSON.generate(data)
    LOG.info("#{Vcert::VCERT_PREFIX} POST request: #{request.inspect}\n\tpath: #{url}\n\tdata: #{encoded_data}")
    response = request.post(url, encoded_data, {TOKEN_HEADER_NAME => @token[0], "Content-Type" => "application/json"})
    data = JSON.parse(response.body)
    return response.code.to_i, data
  end

  def get(url)
    if @token == nil || @token[1] < DateTime.now
      auth()
    end
    uri = URI.parse(@url)
    request = Net::HTTP.new(uri.host, uri.port)
    request.use_ssl = true
    if @trust_bundle != nil
      request.ca_file = @trust_bundle
    end
    url = uri.path + url
    LOG.info("#{Vcert::VCERT_PREFIX} GET request: #{request.inspect}\n\tpath: #{url}")
    response = request.get(url, { TOKEN_HEADER_NAME => @token[0] })
    # TODO: check valid json
    data = JSON.parse(response.body)
    return response.code.to_i, data
  end

  def policy_dn(zone)
    if zone == nil || zone == ''
      raise Vcert::ClientBadDataError, "Zone should not be empty"
    end
    if zone =~ /^\\\\VED\\\\Poplicy/
      return zone
    end
    if zone =~ /^\\\\/
      return '\\VED\\Policy' + zone
    else
      return '\\VED\\Policy\\' + zone
    end
  end

  def normalize_url(url)
    if url.index('http://') == 0
      url = "https://" + url[7..-1]
    elsif url.index('https://') != 0
      url = 'https://' + url
    end
    unless url.end_with?('/')
      url = url + '/'
    end
    unless url.end_with?('/vedsdk/')
      url = url + 'vedsdk/'
    end
    unless url =~ /^https:\/\/[a-z\d]+[-a-z\d.]+[a-z\d][:\d]*\/vedsdk\/$/
      raise Vcert::ClientBadDataError, "Invalid URL for TPP"
    end
    url
  end

  def parse_full_chain(full_chain)
    pems = parse_pem_list(full_chain)
    Vcert::Certificate.new cert: pems[0], chain: pems[1..-1], private_key: nil
  end

  def search_by_thumbprint(thumbprint)
    # thumbprint = re.sub(r'[^\dabcdefABCDEF]', "", thumbprint)
    thumbprint = thumbprint.upcase
    status, data = get(URL_CERTIFICATE_SEARCH+"?Thumbprint=#{thumbprint}")
    # TODO: check that data have valid certificate in it
    if status != 200
      raise Vcert::ServerUnexpectedBehaviorError, "Status: #{status}. Message:\n #{data.body.to_s}"
    end
    # TODO: check valid data
    return data['Certificates'][0]['DN']
  end

  def parse_zone_configuration(data)
    s = data["Policy"]["Subject"]
    country = Vcert::CertField.new s["Country"]["Value"], locked: s["Country"]["Locked"]
    state = Vcert::CertField.new s["State"]["Value"], locked: s["State"]["Locked"]
    city = Vcert::CertField.new s["City"]["Value"], locked: s["City"]["Locked"]
    organization = Vcert::CertField.new s["Organization"]["Value"], locked: s["Organization"]["Locked"]
    organizational_unit = Vcert::CertField.new s["OrganizationalUnit"]["Values"], locked: s["OrganizationalUnit"]["Locked"]
    key_type = Vcert::KeyType.new data["Policy"]["KeyPair"]["KeyAlgorithm"]["Value"], data["Policy"]["KeyPair"]["KeySize"]["Value"]
    Vcert::ZoneConfiguration.new country: country, province: state, locality: city, organization: organization,
                                 organizational_unit: organizational_unit, key_type: Vcert::CertField.new(key_type)
  end

  def parse_policy_response(response, zone_tag)
    def addStartEnd(s)
      unless s.index("^") == 0
        s = "^" + s
      end
      unless s.end_with?("$")
        s = s + "$"
      end
      s
    end

    def escape(value)
      if value.kind_of? Array
        return value.map { |v| addStartEnd(Regexp.escape(v)) }
      else
        return addStartEnd(Regexp.escape(value))
      end
    end

    policy = response["Policy"]
    s = policy["Subject"]
    if policy["WhitelistedDomains"].empty?
      subjectCNRegex = [ALL_ALLOWED_REGEX]
    else
      if policy["WildcardsAllowed"]
        subjectCNRegex = policy["WhitelistedDomains"].map { |d| addStartEnd('[\w\-*]+' + Regexp.escape("." + d)) }
      else
        subjectCNRegex = policy["WhitelistedDomains"].map { |d| addStartEnd('[\w\-]+' + Regexp.escape("." + d)) }
      end
    end
    if s["OrganizationalUnit"]["Locked"]
      subjectOURegexes = escape(s["OrganizationalUnit"]["Values"])
    else
      subjectOURegexes = [ALL_ALLOWED_REGEX]
    end
    if s["Organization"]["Locked"]
      subjectORegexes = [escape(s["Organization"]["Value"])]
    else
      subjectORegexes = [ALL_ALLOWED_REGEX]
    end
    if s["City"]["Locked"]
      subjectLRegexes = [escape(s["City"]["Value"])]
    else
      subjectLRegexes = [ALL_ALLOWED_REGEX]
    end
    if s["State"]["Locked"]
      subjectSTRegexes = [escape(s["State"]["Value"])]
    else
      subjectSTRegexes = [ALL_ALLOWED_REGEX]
    end
    if s["Country"]["Locked"]
      subjectCRegexes = [escape(s["Country"]["Value"])]
    else
      subjectCRegexes = [ALL_ALLOWED_REGEX]
    end
    if policy["SubjAltNameDnsAllowed"]
      if policy["WhitelistedDomains"].length == 0
        dnsSanRegExs = [ALL_ALLOWED_REGEX]
      else
        dnsSanRegExs = policy["WhitelistedDomains"].map { |d| addStartEnd('[\w-]+' + Regexp.escape("." + d)) }
      end
    else
      dnsSanRegExs = []
    end
    if policy["SubjAltNameIpAllowed"]
      ipSanRegExs = [ALL_ALLOWED_REGEX] # todo: support
    else
      ipSanRegExs = []
    end
    if policy["SubjAltNameEmailAllowed"]
      emailSanRegExs = [ALL_ALLOWED_REGEX] # todo: support
    else
      emailSanRegExs = []
    end
    if policy["SubjAltNameUriAllowed"]
      uriSanRegExs = [ALL_ALLOWED_REGEX] # todo: support
    else
      uriSanRegExs = []
    end

    if policy["SubjAltNameUpnAllowed"]
      upnSanRegExs = [ALL_ALLOWED_REGEX] # todo: support
    else
      upnSanRegExs = []
    end
    unless policy["KeyPair"]["KeyAlgorithm"]["Locked"]
      key_types = [1024, 2048, 4096, 8192].map { |s| Vcert::KeyType.new("rsa", s) } + Vcert::SUPPORTED_CURVES.map { |c| Vcert::KeyType.new("ecdsa", c) }
    else
      if policy["KeyPair"]["KeyAlgorithm"]["Value"] == "RSA"
        if policy["KeyPair"]["KeySize"]["Locked"]
          key_types = [Vcert::KeyType.new("rsa", policy["KeyPair"]["KeySize"]["Value"])]
        else
          key_types = [1024, 2048, 4096, 8192].map { |s| Vcert::KeyType.new("rsa", s) }
        end
      elsif policy["KeyPair"]["KeyAlgorithm"]["Value"] == "EC"
        if policy["KeyPair"]["EllipticCurve"]["Locked"]
          curve = {"p224" => "secp224r1", "p256" => "prime256v1", "p521" => "secp521r1"}[policy["KeyPair"]["EllipticCurve"]["Value"].downcase]
          key_types = [Vcert::KeyType.new("ecdsa", curve)]
        else
          key_types = Vcert::SUPPORTED_CURVES.map { |c| Vcert::KeyType.new("ecdsa", c) }
        end
      end
    end

    Vcert::Policy.new(policy_id: policy_dn(zone_tag), name: zone_tag, system_generated: false, creation_date: nil,
                      subject_cn_regexes: subjectCNRegex, subject_o_regexes: subjectORegexes,
                      subject_ou_regexes: subjectOURegexes, subject_st_regexes: subjectSTRegexes,
                      subject_l_regexes: subjectLRegexes, subject_c_regexes: subjectCRegexes, san_regexes: dnsSanRegExs,
                      key_types: key_types)
  end
end


