#!/usr/bin/ruby

require 'rubygems'
require 'mechanize'
require 'logger'
require 'json'
require 'fusefs'

class ACDClient
  def initialize(user=false, pass=false)
    @base_uri = 'https://www.amazon.com/clouddrive/'
    @agent = Mechanize.new
    @agent.log = Logger.new "mech.log"

    signin user, pass if user && pass
  end

  def signin(user, pass)
    @agent.get @base_uri do |page|
      actions = page.form_with(:name => "signIn") { |f| f.email=user;f.password=pass }.click_button

      actions.body.scan(/\<input[^\<]+/) do |input|
        @cust_id = $1 if input.index("customerId") && /value="([^"]*)"/.match(input)
        @sess_id = $1 if input.index("sessionId") && /value=([^"]*)"/.match(input)
      end
    end

    @session_id = @agent.cookies().find { |c| c.name =='session-id' }.value
  end

  def get(op, params = {})
    resp = @agent.get @base_uri +'api/', default_params(op).merge(params), nil, {'x-amzn-SessionId' => @session_id}
    JSON.parse(resp.body)
  end

  def default_params(op)
    { "Operation" => op, "_" => Time.now.to_i, "customerId" => @cust_id, "ContentType" => "JSON" }
  end

  def get_path_info(path)
    get "getInfoByPath",  { "path" => path, "populatePath" => "true" }
  end

  def list_by_id(parent_obj_id)
    get "listById", { "objectId" => parent_obj_id, "nextToken" => 0, "ordering" => "keyName", "filter" => "type != 'RECYCLE' and status != 'PENDING' and hidden = false" }
  end

  def download_by_id(obj_id)
    @agent.get(@base_uri, { "downloadById" => obj_id, "attachment" => 1 }).content
  end
end


class AmazonCloudDriveFS < FuseFS::FuseDir

  def initialize(user, pass)
    @acd = ACDClient.new(user, pass)
    @obj_cache = Hash.new
  end

  def contents(path="/")
    get_path_obj(path)[:children].collect { |x| x["name"] }
  end

  def file?(path)
    get_path_obj(path)[:path_info]["type"].match("FILE")
  end
 
  def directory?(path)
    get_path_obj(path)[:path_info]["type"].match(/ROOT|FOLDER/)
  end

  def read_file(path)
    @acd.download_by_id(get_path_obj(path)[:path_info]["objectId"])
  end

  def get_path_obj(path)
    return @obj_cache[path] if @obj_cache.has_key?(path)

    path_info = @acd.get_path_info(path)
    @obj_cache[path] = { :path_info => path_info["getInfoByPathResponse"]["getInfoByPathResult"] }
    
    
    children = @acd.list_by_id(@obj_cache[path][:path_info]["objectId"])
    @obj_cache[path][:children] = children["listByIdResponse"]["listByIdResult"]["objects"]

    ## create new path entry for each child file to minimize server hits
    @obj_cache[path][:children].each do |c|
      @obj_cache[c["path"]] = { :path_info => c } unless c["type"].match(/ROOT|FOLDER/) || @obj_cache.has_key?(c["path"])
    end

    @obj_cache[path]
  end
end

root = AmazonCloudDriveFS.new(*(File.read("credentials").split))
FuseFS.set_root(root)

FuseFS.mount_under ARGV.shift
FuseFS.run
 
