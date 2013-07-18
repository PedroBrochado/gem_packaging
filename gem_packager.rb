#!/usr/bin/ruby

require "optparse"
require "yaml"

options = {:default => "args"}

ARGV.options do |opts|
	opts.banner = "Usage:  #{File.basename($PROGRAM_NAME)} [OPTIONS] OTHER_ARGS"

	opts.separator ""
	opts.separator "Specific Options:"

	opts.on( "-d", "--debug", "run in debug mode") do
		options[:debug] = true
	end

	opts.on( "-f", "--file PATH_TO_FILE", "File containing the gem list" ) do | list |
		options[:hash] = YAML.load(File.read(list))
		if options[:debug]
			puts options[:hash]
		end
	end

	opts.on( "-o", "--output PATH_TO_FILE", "Output file" ) do | output |
		options[:output] = output
		if options[:debug]
			puts options[:output]
		end
	end

	opts.separator "Common Options:"

	opts.on( "-h", "--help", "Show this message." ) do
		puts opts
		exit
	end

	begin
		opts.parse!
	rescue Exception => e
		puts opts
		exit
	end
end
