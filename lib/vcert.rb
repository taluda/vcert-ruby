require 'net/https'


module Vcert
  class Connection
    def initialize(url=nil, user=nil, password=nil, cloud_token=nil,)
      if cloud_token != nil then
        @conn = CloudConnection.new url, token
      elsif user != nil && password != nil && url != nil then
        @conn = TPPConnection.new url, user, password
      else
        raise "Invalid credentials list" # todo: add typed exceptions
      end
    end

    def request(*args)
      @conn.request(*args)
    end
  end
end


require 'cloud/cloud'
require 'tpp/tpp'
