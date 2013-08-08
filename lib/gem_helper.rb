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
require "net/sftp"
require 'capybara'
require 'capybara/poltergeist'

module GemPackager
	class GemHelper
		include Singleton

		@@gem_list
		@@format = 'json'
		@@url = "rubygems.org/api/v1/"

		class << self
			attr_accessor :gem, :version, :file, :output, :debug, :proxy, :ftp

			def load
				if file.nil?
					@@gem_list = {gem => version}
				else
					@@gem_list = YAML.load(File.read(file))['gems']
				end

				@@gem_list.each_pair { |name, val|
					if val.eql? 'nil' or val.nil?
						@@gem_list[name] = get_last_version(name)['version']
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

			def get_last_version gem_name
				uri = "http://#{@@url}gems/#{gem_name}.#{@@format}"
				return JSON.parse(http_call(uri))
			end

			def get_specific_version gem_name
				uri = "http://bundler.#{@@url}dependencies.#{@@format}?gems=#{gem_name}"
				return JSON.parse(http_call(uri))
			end

			def normalize_gem_version gem_version
				symbol = nil
        gem_version.gsub!(',', '')
				if gem_version.include? ' '
					symbol = gem_version.split(' ')[0]
					gem_version = gem_version.split(' ')[1]
				end
				while gem_version.count('.') < 2
					gem_version << ".0"
				end
				return gem_version, symbol
			end

			def process_version_symbol gem_info, gems_array = nil
				version, symbol = normalize_gem_version(gem_info.values[0])
				case symbol
				when '>='
					return get_last_version(gem_info.keys[0])['version']
				when '~>', '<'
					unless gems_array
						gems_array = get_specific_version gem_info.keys[0]
					end
					default = '0.0.0'
					if symbol.eql? '<'
						superior = Gem::Version.new(version)
					else
						superior = Gem::Version.new("#{version[0].to_i + 1}.0.0")
					end
					gems_array.each { |version|
						gem_version = Gem::Version.new(version['number'])
						if gem_version >= Gem::Version.new(default) && gem_version < superior
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

				fetched_information = get_correct_gem_version(gem_info, get_specific_version(gem_name))

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

			#
			# files can be a string as "*.rpm" ?
			#
			def send_rpms_to_ftp files, ftp, ftp_folder, username = nil, password = nil
				Net::SFTP.start(ftp, username, :password => password) do |sftp|
					Dir.glob(files).each { |file|
						sftp.upload!(file, "#{ftp_folder}/#{file}")
					}
				end
			end

			def create_wiki_pages gems
				gems_array = analyze_gem_version gems
				@@browser = Capybara::Session.new :poltergeist
				@@browser.visit 'http://jira.ptin.corppt.com/secure/?os_username=ci-tc&os_password=c1-tc'

				gems_array.each { |gem_hash|
					create_gem_wiki_page gem_hash
					puts Hash[gem_hash.keys[0], process_version_symbol(gem_hash)]
				}
				@@browser.close
			end

			def create_gem_wiki_page gem_info
				fetched_information = get_correct_gem_version(gem_info, get_specific_version(gem_info.keys[0]))

				# de momento está a ser usado um link na nossa wiki
				# browser.visit 'http://wiki.ptin.corppt.com/display/EXMIRRORS/Lista+de+Componentes+Empacotados'
				@@browser.visit 'http://wiki.ptin.corppt.com/display/TESTC/Manuais'

				new_page = @@browser.has_css? 'createlink'
				@@browser.click_link "rubygem-#{gem_info.keys[0]}"

				html_string = "<li>versão #{gem_info.values[0]}<ul>"
				fetched_information["dependencies"].each { |dependency|
					html_string << "<li>#{dependency[0]} #{dependency[1].gsub('>', '&gt;')}</li>"
				}
				html_string << '</ul></li>'

				addition_type = ''
				insert_on = nil

				if new_page
					full_page = "<h1>Descrição</h1><p>#{get_last_version(gem_info.keys[0])['info']}</p>"
					full_page << "<h1>Dependências</h1><ul>#{html_string}</ul>"
					full_page << "<h1>Licença</h1><p>MIT</p>"
					full_page << "<h1>Equipa</h1><p>Mauro Rodrigues</p>"

					html_string = full_page

					element = 'document.getElementById("tinymce")'
					addition_type = '='
				else
					@@browser.click_link 'Edit'

					element = '(document.getElementsByTagName("h1")[1]).nextSibling'
					addition_type = '+='
				end

				script ="#{element}.innerHTML #{addition_type} '#{html_string}'"
				puts script

				@@browser.within_frame 'wysiwygTextarea_ifr' do
					@@browser.execute_script script
				end

				@@browser.click_button 'rte-button-publish'
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

				parser.on('-u', '--upload FTP', "FTP to commit files") do |ftp|
					GemHelper.ftp = ftp
				end

				parser.separator 'Common Options:'
				parser.on('-p', '--proxy PROXY', 'Proxy to use') do |proxy|
					GemHelper.proxy = proxy
				end

				parser.on('-d', '--debug', 'Run in Debug Mode') do
					GemHelper.debug = true
				end

				parser.on('-h', '--help', 'Show Script Helper' ) do
					puts parser.help
					exit
				end
			end

			opts.parse!(args)
			GemHelper.load
		end
	end
end

GemPackager::GemHelperParser.parse(ARGV)

gem_hash = GemPackager::GemHelper.get_gem_list
gem_array = GemPackager::GemHelper.get_dependencies_array gem_hash

GemPackager::GemHelper.print_dependency_tree gem_hash
puts GemPackager::GemHelper.get_dependencies_string gem_hash

# GemPackager::GemHelper.send_rpms_to_ftp '*.rpm', '10.112.26.247', '/opt/jenkins', 'jenkins', 'jenkins'
# GemPackager::GemHelper.create_wiki_pages gem_array
