#--
# Cloud Foundry 2012.02.03 Beta
# Copyright (c) [2009-2012] VMware, Inc. All Rights Reserved.
#
# This product is licensed to you under the Apache License, Version 2.0 (the "License").
# You may not use this product except in compliance with the License.
#
# This product includes a number of subcomponents with
# separate copyright notices and license terms. Your use of these
# subcomponents is subject to the terms and conditions of the
# subcomponent's license, as noted in the LICENSE file.
#++

require 'highline'
require 'optparse'

module CF; module UAA end end

module CF::UAA

class Topic

  def self.option_defs ; @option_defs || {} end
  def self.commands; @commands || {} end
  def self.topic(description = nil) description ? (@description = description) : @description end

  def self.define_option(key, *args)
    @option_defs ||= {}
    raise "conflicting option definition for #{key}" if @option_defs.key?(key) && @option_defs[key] != args
    @option_defs[key] = args
  end

  def self.desc(template, desc, options = [], &handler)
    parts, argc = template.split(' '), 0
    cmd = parts.each_with_object([]) { |p, o|
      case p
      when /\.\.\.\]$/ then argc = -1; break o
      when /^\[/ then argc = parts.length - o.length; break o
      else o << p
      end
    }
    cmd_key = cmd.join('_').to_sym
    define_method(cmd_key, handler)
    @commands ||= {}
    @commands[cmd_key] = {parts: cmd, argc: argc, template: template, desc: desc, options: options}
  end

  def initialize(cli_class, options = {}, input = $stdin, output = $stdout)
    @cli_class, @options, @input, @output = cli_class, options, input, output
    @highline = HighLine.new(input, output)
  end

  def ask(prompt); @highline.ask("#{prompt}:  ") end
  def ask_pwd(prompt); @highline.ask("#{prompt}:  ") { |q| q.echo = '*' } end
  def say(*args); @output.puts args end
  def opts; @options end

  def terminal_columns
    return @terminal_columns ||= 0 if @terminal_columns || !@output.tty?
    cols = HighLine::SystemExtensions.terminal_size.first rescue 0
    @terminal_columns = !cols || cols < 40 ? 0 : cols
  end

  def help_col_start
    return @help_col_start ||= 35 if @help_col_start || terminal_columns == 0 || terminal_columns > 80
    @help_col_start = terminal_columns / 2
  end

  def pp(obj, indent = 0, wrap = terminal_columns, label = nil)
    #line = indent_count == 0 ? "#{label}": sprintf("%*c%s", indent_count * indent_size, ' ', label)
    case obj
    when Array
      if obj.empty? || !obj[0].is_a?(Hash) && !obj[0].is_a?(Array)
        say_definition(indent, label, Util.strlist(obj), nil, wrap)
      else
        say_definition(indent, label, nil, nil, wrap) if label
        obj.each {|o| pp o, indent, wrap, '-' }
      end
    when Hash
      say_definition(indent, label, nil, nil, wrap) if label
      obj.each { |k, v| pp v, indent + 2, wrap, "#{k}: " }
    else say_definition(indent, label, obj.to_s, nil, wrap)
    end
  end

  def say_definition(indent, term, text = nil, start = help_col_start, wrap = terminal_columns)
    cur = indent + (term ? term.length : 0)
    indent < 1 ? @output.printf("%s", term) : @output.printf("%*c%s", indent, ' ', term)
    if start.nil?
      start = 2 if (start = indent + 4) > wrap
    else
      start = 2 if start > wrap
      if cur < start
        @output.printf("%*c", start - cur, ' ')
      elsif cur > start
        @output.printf("\n%*c", start, ' ')
      end
      cur = start
    end
    return @output.printf("\n") unless text && !text.empty?
    text = text.dup
    text.each_line do |line|
      width = wrap == 0 ? 4096 : wrap - cur
      line = line.chomp
      while line.length > width
        i = line.rindex(' ', width) || width
        @output.printf("%s\n%*c", line[0..i - 1], start, ' ')
        width = wrap == 0 ? 4096 : wrap - start
        line = line[i..-1].strip
      end
      @output.printf("%s\n", line)
      cur = start
    end
  end

  def opt_help(key, args)
    raise "missing option definition for #{key}" unless args
    long = short = desc = nil
    args.each do |a|
      case a
      when /^-.$/ then short = a
      when /^--.*/ then long = a
      else desc = a
      end
    end
    raise "option definition must include long form (--#{key})" unless long
    [ short ? "#{short} | #{long}" : "#{long}", desc]
  end

  def say_cmd_helper(info, suffix = nil)
    say_definition 2, info[:template], info[:desc]
    info[:options].each do |o|
      odef, desc = opt_help(o, @cli_class.option_defs[o])
      say_definition help_col_start, "", desc ? "#{odef}, #{desc}" : odef
    end
    @output.print suffix
  end

  def say_command_help(args)
    say ""
    @cli_class.topics.each do |tpc|
      tpc.commands.each do |k, v|
        return say_cmd_helper(v, "\n") if args[0..v[:parts].length - 1] == v[:parts]
      end
    end
    args = args.map(&:downcase)
    @cli_class.topics.each { |tpc| return say_help(tpc) unless (args & tpc.topic.downcase.split(' ')).empty? }
    say "No command or topic found to match: #{args.join(' ')}", ""
  end

  def say_help(topic = nil)
    @output.print "\n#{@cli_class.overview}\n" unless topic
    @cli_class.topics.each do |tpc|
      next if topic && topic != tpc
      @output.print "\n#{tpc.topic}\n"
      tpc.commands.each { |k, v| say_cmd_helper v }
    end
    return @output.print("\n") if topic || !@cli_class.global_options
    @output.print "\nGlobal options:\n"
    @cli_class.global_options.each do |o|
      odef, desc = opt_help(o, @cli_class.option_defs[o])
      say_definition 2, odef, desc
    end
    @output.print("\n")
  end

end

class BaseCli

  class << self
    attr_reader :input, :output, :option_defs
    attr_accessor :overview, :topics, :global_options
  end

  def self.preprocess_options(args, opts); end # to be implemented in subclass
  def self.too_many_args(cmd); end # to be implemented in subclass

  def self.run(args = ARGV)
    @input ||= $stdin
    @output ||= $stdout
    @option_defs = {}
    args = args.split if args.respond_to?(:split)
    @parser = OptionParser.new
    opts = @topics.each_with_object({}) do |tpc, o|
      tpc.option_defs.each do |k, optdef|
        @parser.on(*optdef) { |v| o[k] = v }
        @option_defs[k] = optdef
      end
    end
    @parser.parse! args
    preprocess_options(args, opts)
    @topics.each do |tpc|
      tpc.commands.each do |k, v|
        next unless args[0..v[:parts].length - 1] == v[:parts]
        args = args[v[:parts].length..-1]
        if v[:argc] == -1
          # variable args, leave args alone
        elsif args.length > v[:argc]
          too_many_args(v[:parts].dup)
          return self
        elsif args.length < v[:argc]
          (v[:argc] - args.length).times { args << nil }
        end
        tpc.new(self, opts, @input, @output).send(k, *args)
        return self
      end
    end
    @output.puts "#{$0} subcommand not found"
    self
  rescue Exception => e
    $stderr.puts "", "#{e.class}: #{e.message}", (e.backtrace if opts[:trace])
    #$stderr.puts "", "#{e.class}: #{e.message}", e.backtrace
  end

end

end
