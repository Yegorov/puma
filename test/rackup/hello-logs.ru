require 'logger'
class AppWithLogger
  def initialize
    @logger = Logger.new('test/log.log')
  end

  def call(env)
    ObjectSpace.each_object(File) do |file|
      @logger.info file.path
    end
    @logger.info "hello"
    [200, {"Content-Type" => "text/plain"}, ["Hello World"]]
  end
end

run AppWithLogger.new
