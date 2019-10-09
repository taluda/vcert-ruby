require 'json'
require 'date'
require 'base64'

class Vcert::TPPConnection
  def initialize(url, user, password)
    @url = normalize_url url
    @user = user
    @password = password
    @token = nil
  end

  def request(zone_tag, request)
    data={:PolicyDN => policy_dn(zone_tag),
                  :PKCS10 => request.csr,
                  :ObjectName =>  request.friendly_name,
                  :DisableAutomaticRenewal =>  "true"}
    code, response = post URL_CERTIFICATE_REQUESTS, data
    if code != 200
      puts response
      raise "Bad server status code #{code}"
    end
    request.id = response['CertificateDN']
  end

  def retrieve(request)
    retrieve_request = {CertificateDN: request.id, Format: "base64", IncludeChain: 'true', RootFirstOrder: "false"}
    code, response = post CERTIFICATE_RETRIEVE, retrieve_request
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

  private
  URL_AUTHORIZE = "authorize/"
  URL_CERTIFICATE_REQUESTS = "certificates/request"
  CERTIFICATE_RETRIEVE = "certificates/retrieve"
  TOKEN_HEADER_NAME = "x-venafi-api-key"
  def auth
    uri = URI.parse(@url)
    request = Net::HTTP.new(uri.host, uri.port)
    request.use_ssl = true
    request.verify_mode = OpenSSL::SSL::VERIFY_NONE  # todo: investigate verifying
    url = uri.path + URL_AUTHORIZE
    data = {:Username => @user, :Password => @password}
    encoded_data = JSON.generate(data)
    response = request.post(url ,encoded_data, {"Content-Type" => "application/json"})
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
    request.verify_mode = OpenSSL::SSL::VERIFY_NONE # todo: investigate verifying
    url = uri.path + url
    encoded_data = JSON.generate(data)
    response = request.post(url, encoded_data,  {TOKEN_HEADER_NAME => @token[0], "Content-Type" => "application/json"})
    data = JSON.parse(response.body)
    return response.code.to_i, data
  end

  def get
    if @token == nil || @token[1] < DateTime.now
      auth()
    end
    uri = URI.parse(@url)
    request = Net::HTTP.new(uri.host, uri.port)
    request.use_ssl = true
    request.verify_mode = OpenSSL::SSL::VERIFY_NONE  # todo: investigate verifying
    url = uri.path + url
    response = request.get(url,{TOKEN_HEADER_NAME => @token[0]})
    data = JSON.parse(response.body)
    return response.code.to_i, data
  end

  def policy_dn(zone)
    if zone == nil || zone == ''
      raise "Empty zone"
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
    elsif url.index('https://') !=0
      url = 'https://' + url
    end
    unless url.end_with?('/')
      url = url + '/'
    end
    unless url.end_with?('/vedsdk/')
      url = url + 'vedsdk/'
    end
    unless url =~ /^https:\/\/[a-z\d]+[-a-z\d.]+[a-z\d][:\d]*\/vedsdk\/$/
      raise("bad TPP url")
    end
    url
  end

  def parse_full_chain(full_chain)
    Vcert::Certificate.new  full_chain, '', nil # todo: parser
  end

  def parse_pem_list(multiline)
    pems = []
    buf = ""
    current_string_is_pem = false
    multiline.each_line do |line|
      if line.match(/-----BEGIN [A-Z]+-----/)
        current_string_is_pem = true
      end
      if current_string_is_pem
        buf = buf + line
      end
      if line.match(/-----END [A-Z]+-----]/)
        current_string_is_pem = false
        pems.push(buf)
        buf = ""
      end
    end
    pems
  end
end


