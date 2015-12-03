#!/usr/bin/env ruby 

require_relative 'config'

require 'socket'
require 'qos-info'

$DEBUG = true

# 傳送資料間隔
MONITOR_INTERVAL = 0.05
MONITOR_DETECT_INTERVAL = MONITOR_INTERVAL / 10.0
$max_spd = MAX_SPEED / UNIT_MEGA

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
# 更改queue最大速度
def set_max_speed(speed)
  return if defined?(NO_SPEED_LIMIT_FOR) && NO_SPEED_LIMIT_FOR.include?($port)
  IO.popen "tc class change dev #{$port} classid 1:#{$qid} htb rate 12Kbit ceil #{speed}Mbit"
end

# 不斷取得queue len
begin
  last_time = Time.now
  loop do
    # Timing compute
    this_time = Time.now
    if this_time - last_time < MONITOR_INTERVAL
      sleep MONITOR_DETECT_INTERVAL
      next
    end
    last_time = Time.now
    $q_data = data =  get_queue_len($qid)
    len = data[:len]
    if len >= 500
      puts "在#{Time.now.to_f}發起！" if DEBUG_TIMING
    end
    if len >= 0 
      # 畫圖
      bar_len = (len / 20.0).ceil
      printf("%5d,速度上限：%3d Mbits ,Queue:%s\n",len,data[:spd],"|"*bar_len) if MONITOR_SHOW_INFO
    end

  end
rescue SystemExit, Interrupt
  $controller_sock.puts "close"
  $controller_sock.close
end
