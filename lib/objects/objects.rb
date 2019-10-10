require 'openssl'


module Vcert
  class Request
    def initialize(common_name: nil, private_key: nil, key_type: "rsa", key_length: 2048, key_curve: "prime256v1",
                   organization: nil,  organizational_unit: nil, country: nil, province: nil, locality:nil, san_dns:nil,
                   friendly_name: nil, csr: nil)
      @common_name = common_name
      @private_key = private_key
      @key_type = key_type
      @key_length = key_length
      @key_curve = key_curve
      @organization = organization
      @organizational_unit = organizational_unit
      @country = country
      @province = province
      @locality = locality
      @san_dns = san_dns
      @friendly_name = friendly_name
      @id = nil
      @csr = csr
    end

    def generate_csr
      if @private_key == nil
        generate_private_key
      end
      subject_attrs = [
          ['CN', @common_name]
      ]
      if @organization != nil
        subject_attrs.append(['O', @organization])
      end
      if @organizational_unit != nil
        subject_attrs.append(['OU', @organizational_unit])
      end
      if @country != nil
        subject_attrs.append(['C', @country])
      end
      if @province !=  nil
        subject_attrs.append(['ST', @province])
      end
      if @locality != nil
        subject_attrs.append(['L', @locality])
      end

      subject = OpenSSL::X509::Name.new subject_attrs
      csr = OpenSSL::X509::Request.new
      csr.version = 0
      csr.subject = subject
      csr.public_key = @private_key.public_key
      if @san_dns != nil
        san_list = @san_dns.map { |domain| "DNS:#{domain}" }
        extensions = [
            OpenSSL::X509::ExtensionFactory.new.create_extension('subjectAltName', san_list.join(','))
        ]
        attribute_values = OpenSSL::ASN1::Set [OpenSSL::ASN1::Sequence(extensions)]
        [
            OpenSSL::X509::Attribute.new('extReq', attribute_values),
            OpenSSL::X509::Attribute.new('msExtReq', attribute_values)
        ].each do |attribute|
          csr.add_attribute attribute
        end
      end
      csr.sign @private_key, OpenSSL::Digest::SHA256.new # todo: changable sign alg
      @csr = csr.to_pem
    end

    def csr
      if @csr == nil
        generate_csr
      end
      @csr
    end

    def private_key
      if @private_key == nil
        generate_private_key
      end
      @private_key.to_pem
    end

    def friendly_name
      if @friendly_name != nil
        return @friendly_name
      end
      @common_name
    end

    def id
      @id
    end

    def id=(value)
      @id = value
    end

    def update_from_zone_config(zone_config)

    end
    private


    def generate_private_key
      if @key_type == "rsa"
        @private_key =  OpenSSL::PKey::RSA.new @key_length
      elsif @key_type == "ecdsa"
        @private_key = OpenSSL::PKey::EC.new @key_curve # todo: check
      end
    end
  end

  class Certificate
    def initialize(cert, chain, private_key)
      @cert = cert
      @chain = chain
      @private_key = private_key
    end
    attr_reader :cert
    attr_reader :chain
    attr_accessor :private_key
  end

  class Policy
    attr_reader :policy_id, :name, :system_generated, :creation_date
    def initialize(policy_id, name, system_generated, creation_date, subject_cn_regexes, subject_o_regexes,
                   subject_ou_regexes, subject_st_regexes, subject_l_regexes, subject_c_regexes,  san_regexes,
                   key_types)
      @policy_id = policy_id
      @name = name
      @system_generated = system_generated
      @creation_date = creation_date
      @subject_cn_regexes = subject_cn_regexes
      @subject_c_regexes = subject_c_regexes
      @subject_st_regexes = subject_st_regexes
      @subject_l_regexes = subject_l_regexes
      @subject_o_regexes = subject_o_regexes
      @subject_ou_regexes = subject_ou_regexes
      @san_regexes = san_regexes
      @key_types = key_types
    end

    def check_request(request)

    end

    private
    def check_string_match_regexps(s, regexps)
      return true
    end

  end

  class ZoneConfiguration
    attr_reader  :country, :province, :locality, :organization, :organizational_unit, :key_type
    def initialize(country, province, locality, organization, organizational_unit, key_type)
      @country = country
      @province = province
      @locality = locality
      @organization = organization
      @organizational_unit = organizational_unit
      @key_type = key_type
    end
  end

  class CertField
    attr_reader :value, :locked
    def initialize(value, locked: false )
      @value = value
      @locked = locked
    end
  end
end

