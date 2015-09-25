#!/usr/bin/env ruby 

require 'socket'
require './host-info.rb'

$DEBUG = true

# 傳送資料間隔
MONITOR_INTERVAL = 0.05

SHOW_INFO = false

# 紀錄最後長度
$last_len = 0
# 要監測的s
$sw = ARGV[0]
# 網卡編號 
$eth = ARGV[1]
# 要監測的queue
$qid = $eth.to_i + 1
# Port
$port = "#{$sw}-eth#{$eth}"
# Controller
puts "連接Controller中..."
$controller_sock = TCPSocket.new CONTROLLER_IP_SW,CONTROLLER_PORT
$controller_sock.puts "switch #{$port}"
puts "Controller已連接！"

$q_data = nil

# 取得queue length
def get_queue_len(qid)
    len = -1
    spd = 0
    IO.popen("tc -s class show dev #{$port} classid 1:#{qid}") {|result|
        str = result.read
        if str =~ /backlog \d+b (\d+)p/i
            len =  $1.to_i
            # 取得速度
            str =~ /ceil (\d+)Mbit/i
            spd = $1.to_i
        else
            puts "找不到Queue資訊"
        end
    }
    {len: len,spd: spd}
end
# 通知controller
def notify_controller(data)
    # 傳送資料
    $controller_sock.puts "len=#{data[:len]},spd=#{data[:spd]}"
end
# 讀取controller之速度控制訊息
def listen_for_speed_change
    line = $controller_sock.gets
    # 分析訊息
    speed = $q_data[:spd]
    case line
    when /add/
        data = line.split
        eval "speed = speed #{data[1]}"
    when /mul/
        data = line.split
        eval "speed = (speed * #{data[1]}).round"
    when /assign/
        data = line.split
        speed = data[1].to_i
    end
    speed = 1 if speed < 1
    # 設置速度
    set_max_speed(speed)
end

# 更改queue最大速度
def set_max_speed(speed)
    IO.popen "tc class change dev #{$port} classid 1:#{$qid} htb rate 12Kbit ceil #{speed}Mbit"
end

# 控制速度調整的thread
thr_speed = Thread.new do
    loop do
        listen_for_speed_change
    end
end

# 不斷取得queue len
begin
    loop do
        $q_data = data =  get_queue_len($qid)
        len = data[:len]
        if len >= 0 
            notify_controller(data)
            # 畫圖
            bar_len = (len / 20.0).ceil
            printf("%5d,速度上限：%3d Mbits ,Queue:%s\n",len,data[:spd],"|"*bar_len) if SHOW_INFO
        end

        sleep MONITOR_INTERVAL
    end
rescue SystemExit, Interrupt
    thr_speed.exit
    $controller_sock.puts "close"
    $controller_sock.close
end