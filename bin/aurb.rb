libraries = %w[rubygems zlib facets/minitar facets/ansicode json cgi open-uri fileutils optparse]
for library in libraries do
  require library
end

module Aurb
  Config = Struct.new(:search, :info, :sync, :cache, :dir)

  def self.aur
    @aur ||= Aur.new
  end

  class AurbError < Exception
  end

  class Aur
    attr_accessor :config

    def initialize(&b)
      @config = Config.new('http://aur.archlinux.org/rpc.php?type=search&arg=%s',
                           'http://aur.archlinux.org/rpc.php?type=info&arg=%s',
                           '/var/lib/pacman/sync/%s',
                           '/var/lib/pacman/local',
                           File.join(ENV['HOME'], 'abs'))
      @opts = Opts.new(ARGV)

      instance_eval(&b) if block_given?
    end

    def start
      case @opts[:cmd]
      when :dl
        download(@opts[:pkg])
      when :ss
        puts search(@opts[:pkg])
      end
    end

    def download(package)
      unless File.exists? File.join(@config.dir, package)
        for names in list(package) do
          if names.first == package
            Dir.chdir(@config.dir) do |dir|
              begin
                if in_sync? package, 'community'
                  puts "#{color('==>', :yellow)} Found #{package} in community repo. Pacman will do."
                  exec "sudo pacman -S #{package}"
                else
                  puts "#{color('==>', :yellow)} Downloading #{package}."
                  open("http://aur.archlinux.org/packages/#{package}/#{package}.tar.gz") do |remote|
                    File.open("#{dir}/#{package}.tar.gz", 'wb') do |file|
                      file.write(remote.read)
                    end
                  end
                end
              end

              puts "#{color('==>', :yellow)} Unpacking #{package}."
              Archive::Tar::Minitar.unpack(
                Zlib::GzipReader.new(File.open("#{package}.tar.gz", 'rb')),
                Dir.pwd
              )
            end
          end
        end
      else
        raise AurbError, "#{color('Fatal', :on_red)}: directory already exists"
      end
    end

    def search(package)
      threads = []
      count = 0

      for name in list(package) do
        threads << Thread.new do
          result = JSON.parse(open(@config.info % name[1]).read)

          if result['type'] == 'error'
            raise AurbError, "#{color('Fatal', :on_red)}: no results"
          else
            result = result['results']
            next if in_sync? result['Name'], 'community'

            if package.any? do |pac|
                result['Name'].include? pac or result['Description'].include? pac
              end
              count += 1

              puts "#{color(result['Name'], :blue)} (#{result['Version']}): #{result['Description']}"
            end
          end
        end
      end
      threads.each { |t| t.join }

      return "\nFound #{color(count.to_s, :magenta)} #{count == 1 ? 'result' : 'results'}."
    end

  private
    def color(text, *effects)
      colored = ' '
      for effect in effects do
        colored << ANSICode.send(effect)
      end
      colored << text << ANSICode.clear

      return colored[1..-1]
    end

    def in_sync?(package, repo)
      repo = @config.sync % repo
      return true if Dir["#{repo}/#{package}-*"].first
    end

    def in_cache?(package)
      cached = @config.cache
      return true if Dir["#{cached}/#{package}-*"].first
    end

    def list(package)
      info = JSON.parse(open(@config.search % CGI::escape(package)).read)
      list = []

      if info['type'] == 'error'
        raise AurbError, "#{color('Fatal', :on_red)}: #{info['results']}"
      end

      for result in info['results'] do
        list << [result['Name'], result['ID']]
      end

      return list.sort
    end
  end

  class Opts < Hash
    def initialize(args)
      parse(args)
    end

  private
    def parse(args)
      OptionParser.new do |op|
        op.on('-D pkg') { |p| self[:cmd] = :dl; self[:pkg] ||= p }
        op.on('-S pkg') { |p| self[:cmd] = :ss; self[:pkg] ||= p }
      end.parse!(args)
    end
  end
end

at_exit do
  unless defined? Test::Unit
    raise $! if $!
    Aurb.aur.start
  end
end
