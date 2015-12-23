#!/usr/bin/env ruby 

require_relative 'config'


require 'socket'
require 'thread'
require 'qos-lib'
require 'packet_buffer'
require 'packet_handler'
require 'control_api'


SERVER_OPEN_PORT_RANGE = 5001..5008
#SERVER_OPEN_PORT_RANGE = 5005..5005
#SERVER_OPEN_PORT_RANGE = 5002..5002
#SERVER_OPEN_PORT_RANGE = 5008..5008
#SERVER_OPEN_PORT_RANGE = 5005..5008

if SERVER_RANDOM_FIXED_SEED
  srand(0)
end

$host_ip = ARGV[1]
if !$host_ip
  puts "Host IP required"
  exit
end


def run_port_thread(port)
  thr = Thread.new do 
    receiver = PassivePacketHandler.new($pkt_buf,PASSIVE_PORT_TO_IP[port],port)
    $control_api.register_handler(receiver)
    receiver.run_loop
  end
end

def run_read_thread
  thr = Thread.new do
    $pkt_buf.run_receive_loop
  end
end
def run_control_thread
  thr = Thread.new do
    $control_api.run_main_loop
  end
end


pipe_r,pipe_w = IO.pipe

if pid = fork
  loop do
    data = []
    SERVER_OPEN_PORT_RANGE.each do 
      data << pipe_r.gets
    end
    data << pipe_r.gets
    data.each do |str|
      puts str
    end
  end
else
  pipe_r.close
  $stdout.reopen pipe_w
  
  $pkt_buf = PacketBuffer.new($host_ip,$host_ip,SERVER_OPEN_PORT_RANGE)

  holder_list = TARGET_HOSTS_ID[$host_ip].join(',') # who will you send?
  $control_api = ControlAPI.new($host_ip,$host_ip,holder_list)
  $pkt_buf.register_control_api($control_api)
 
  # ///////////
  # Control Loop
  # ///////////
  thr_control = run_control_thread


  # ///////////
  # Pkt Buffer: stop_go_check
  # ///////////
  thr_stop_go_loop = Thread.new do
    $pkt_buf.stop_go_check_loop
  end

  # ///////////
  # Pkt Buffer: writer loop (for premature acks)
  # ///////////
  thr_write = []
  (SERVER_OPEN_PORT_RANGE).each do |port|
    thr_write << Thread.new do
      $pkt_buf.writer_loop(port)
    end
  end

  # ///////////
  # Pkt Buffer: read loop
  # ///////////
  thr_read = run_read_thread
  
  # ///////////
  # Pkt Handler: per-port loop
  # ///////////
  thr_port = []
  (SERVER_OPEN_PORT_RANGE).each do |port|
    thr_port << run_port_thread(port)
  end
  # ///////////
  # main:show info
  # ///////////
  last_rx_size = {}
  last_tx_size = {}
  (SERVER_OPEN_PORT_RANGE).each do |port|
    last_rx_size[port] = 0
    last_tx_size[port] = 0
  end
  last_time = Time.at(0)
  texts = []
  total_rx_diff = 0
  begin
    loop do
      if Time.now - last_time > 1
        total_rx_diff = 0
        texts = []
        last_time = Time.now
        (SERVER_OPEN_PORT_RANGE).each do |port|
          cur_rx = $pkt_buf.total_rx[port]
          rx_diff = cur_rx - last_rx_size[port]
          total_rx_diff += rx_diff
          last_rx_size[port] = cur_rx
  

          cur_tx = $pkt_buf.total_tx[port]
          tx_diff = cur_tx - last_tx_size[port]
          last_tx_size[port] = cur_tx

          rx_loss = $pkt_buf.total_rx_loss[port]
          if cur_rx > 0
            rx_loss_rate = rx_loss * PACKET_SIZE * 100.0 / cur_rx
          else
            rx_loss_rate = 0.0
          end

          text = "#{port}:"
          text += sprintf("[RX]總:%11.3f Mbit，",cur_rx * 8.0 / UNIT_MEGA)
          text += "區:#{(sprintf("%8.3f",rx_diff * 8.0 / UNIT_MEGA))} Mbit，遺失:#{sprintf("%6dp (%6.4f%%)",rx_loss,rx_loss_rate)} "
          text += sprintf("[TX]總:%11.3f Mbit，",cur_tx * 8.0 / UNIT_MEGA)
          text += "區:#{(sprintf("%8.3f",tx_diff * 8.0 / UNIT_MEGA))} Mbit，遺失:#{sprintf('%6d',$pkt_buf.total_tx_loss[port])}p "
          texts << text
        end
      end
      current_q = DCB_SERVER_BUFFER_PKT_SIZE - $pkt_buf.available
      q_rate = (current_q * 100.0)/DCB_SERVER_BUFFER_PKT_SIZE
      printf("===Spd: %8.3f Mbit; Q: %5d(%5.2f%%) :#{'|'*(0.4*q_rate).ceil}\n",total_rx_diff * 8.0 / UNIT_MEGA,current_q,q_rate)
      texts.each do |text|
        print text+"\n"
      end
      sleep 0.1
    end
  rescue SystemExit, Interrupt
    puts "server結束"
  end


end














