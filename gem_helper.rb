#!/usr/bin/ruby
# encoding: utf-8

###
### example of use: ruby gem_helper -f gemlist.yml -p http://proxy:port
###

require 'singleton'
require 'optparse'
require 'yaml'
require 'json'
require 'net/http'

module GemPackager
	class GemHelper
		include Singleton

		@@gem_list
		@@format = 'json'
		@@url = "rubygems.org/api/v1/"

		class << self
			attr_accessor :gem, :version, :file, :output, :debug, :proxy

			def load
				if file.nil?
					@@gem_list = {gem => version}
				else
					@@gem_list = YAML.load(File.read(file))['gems']
				end

				@@gem_list.each_pair { |name, val|
					if val.eql? 'nil' or val.nil?
						@@gem_list[name] = get_last_gem_version name
					end
				}

				if debug
					puts @@gem_list
				end
			end

			def http_call uri
				if proxy.nil?
					result = Net::HTTP.get(URI(uri))
				else
					proxy_uri = URI.parse(proxy)
					http = Net::HTTP::Proxy(proxy_uri.host, proxy_uri.port)
					result = http.get_response(URI.parse(uri)).body
				end
				return result
			end

			def get_last_gem_version gem_name
				uri = "http://#{@@url}gems/#{gem_name}.#{@@format}"
				return JSON.parse(http_call(uri))['version']
			end

			def normalize_gem_version gem_version
				symbol = nil
				if gem_version.include? ' '
					symbol = gem_version.split(' ')[0]
					gem_version = gem_version.split(' ')[1]
				end
				if gem_version.length < 5
					gem_version = gem_version + ".0"
				end
				return gem_version, symbol
			end

			def process_version_symbol gem_info, gems_array = nil
				version, symbol = normalize_gem_version(gem_info.values[0])
				case symbol
				when '>='
					return get_last_gem_version gem_info.keys[0]
				when '~>'
					unless gems_array
						uri = "http://bundler.#{@@url}dependencies.#{@@format}?gems=#{gem_info.keys[0]}"
						gems_array = JSON.parse(http_call(uri))
					end
					default = '0.0.0'
					superior = "#{version[0].to_i + 1}.0.0"
					gems_array.each { |version|
						if version['number'] >= default && version['number'] < superior
							default = version['number']
						end
					}
					return default
				else
					return version
				end
			end

			def get_correct_gem_version gem_info, gems_array
				gem_version = process_version_symbol gem_info
				gems_array.each { |version|
					if version['number'].eql? gem_version
						return version
					end
				}
			end

			def on_yum? gem_name, gem_version
				return system("yum list rubygem-#{gem_name}-#{gem_version} --showduplicates")
			end

			def get_gem_dependencies gem_info
				gem_name = gem_info.keys[0]
				gem_version = gem_info.values[0]

				uri = "http://bundler.#{@@url}dependencies.#{@@format}?gems=#{gem_name}"
				info = JSON.parse(http_call(uri))
				fetched_information = get_correct_gem_version gem_info, info

				if debug
					puts "fetched_information: #{fetched_information}"
				end

				unless fetched_information["dependencies"].empty?
					current_deps = {}
					fetched_information["dependencies"].each { |dependency|
						info = Hash[dependency[0], dependency[1]]
						if debug
							puts dependency
						end
						current_deps.store(info, get_gem_dependencies(info))
					}
					return current_deps
				end
			end

			def get_gem_list
				new_hash = {}
				@@gem_list.each_pair { |name, version|
					new_hash.store(Hash[name, version], get_gem_dependencies({name => version}))
				}
				return new_hash
			end

			def analyze_gem_version gem_list
				unique_list = Hash.new { |hash, key| hash[key] = Array.new }
				gem_list.each { |g|
					unique_list[g.keys[0]] << g.values[0]
				}
				teste = []
				unique_list.each_pair { |key, value|
					teste << {
						key => value.sort { |a, b|
							Gem::Dependency.new(a) <=> Gem::Dependency.new(b)
						}.min
					}
				}
				return teste
			end

			def get_dependencies_string hash
				array = analyze_gem_version(get_dependencies_array(hash))
				string = ''
				array.reverse_each { |gem|
					name, version = gem.keys[0], process_version_symbol(gem)
					unless on_yum? name, version
						string = string + "#{name}-#{version}.gem "
					end
				}
				return string
			end

			def get_dependencies_array hash, array = []
				hash.each_pair { |name, val|
					array.push name
					get_dependencies_array val, array unless val.nil?
				}
				return array
			end

			def print_dependency_tree hash, level = 0
				tab = '└' + '─' * (level * 2 + 1)
				hash.each_pair { |name, val|
					gem_array = name.to_a
					version, symbol = process_version_symbol(name)
					string = "#{gem_array[0][0]} #{version}"
					puts "#{tab} #{string}"
					print_dependency_tree val, level + 1 unless val.nil?
				}
			end
		end
	end

	class GemHelperParser
		def self.parse args
			opts = OptionParser.new do |parser|
				parser.separator 'Specific Options:'

				parser.on('-f', '--file FILE', 'File Containing the Gems to Pack') do |file|
					GemHelper.file = file
				end

				parser.on('-g', '--gem GEM', 'Gem to Pack') do |gem|
					GemHelper.gem = gem
				end

				parser.on('-v', '--version VERSION', 'Version of Gem to Pack. Used WITH --gem') do |version|
					GemHelper.version = version
				end

				parser.on('-p', '--proxy PROXY', 'Proxy to use') do |proxy|
					GemHelper.proxy = proxy
				end

				parser.separator 'Common Options:'
				parser.on('-d', '--debug', 'Run in Debug Mode') do
					GemHelper.debug = true
				end

				parser.on('-h', '--help', 'Show Script Helper' ) do
					puts parser.help
					exit
				end
			end

			opts.parse!(args)
		end
	end
end

GemPackager::GemHelperParser.parse(ARGV)
GemPackager::GemHelper.load

gem_hash = GemPackager::GemHelper.get_gem_list

GemPackager::GemHelper.print_dependency_tree gem_hash
puts GemPackager::GemHelper.get_dependencies_string gem_hash
