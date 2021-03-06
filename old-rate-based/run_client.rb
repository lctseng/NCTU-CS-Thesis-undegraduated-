#!/usr/bin/env ruby 

require_relative 'config'
require 'qos-lib'

pipes = {}
children = {}
last_str = {}

$DEBUG = false
server_ip = ARGV[0]
abort if server_ip.nil?

# Fork all monitors
for n in 2..8
  ip = "172.16.0.#{n}"
  port = 5000 + n
  puts "Starting:#{ip}"
  pipe = IO.pipe
  if pid = fork
    # parent
    children[ip] =  pid
    pipes[ip] = pipe
  else
    # child
    #$stdin.reopen pipe[0]
    $stdout.reopen pipe[1]
    Process.exec "ssh -t root@#{ip} 'cd monitor-mn/sdn-mode;ruby client.rb #{server_ip} #{port}'"
  end
end
# Read from all 
begin
  loop do
    print "========================\n\r"
    pipes.each do |ip,pipe|
      begin
        str = pipe[0].readline_nonblock
        print "#{ip}:#{str}\r"
        last_str[ip] = str
      rescue IO::WaitReadable,IO::EAGAINWaitReadable
        print "#{ip}:#{last_str[ip]}\r"
      rescue SystemExit, Interrupt, SignalException
        exit
      rescue EOFError
        print "#{ip}已關閉通訊！\n\r"
        pipes.delete ip
      end
    end
    sleep 0.1
  end
rescue SystemExit, Interrupt, SignalException
  print "結束中\n\r"
  print "等待children關閉\n\r"
  children.each_value do |pid|
    Process.kill("INT",pid)
    Process.wait pid
  end
end
