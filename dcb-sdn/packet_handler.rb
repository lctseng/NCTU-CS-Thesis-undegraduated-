require_relative 'config'
require 'common'
class PacketHandler

  attr_reader :id
  attr_reader :peer_ip
  attr_reader :port

  attr_reader :token
  attr_reader :lock_file
  attr_accessor :token_getter

  attr_reader :token_lock
  attr_reader :token_ready

  def initialize(pkt_buf,peer_ip,port)
    @pkt_buf = pkt_buf
    @peer_ip = peer_ip
    @port = port
    @id = "#{peer_ip}:#{port}"
    connection_data_reset
    @lock_file = File.open("lock_file/#{@pkt_buf.my_addr}.lock","w")
    @stop = false
    
    @token = 0
    @token_lock = Mutex.new
    @token_ready = ConditionVariable.new

  end
  
  def give_token(n,time)
    @token_lock.synchronize do
      @token += n
      @token_ready.signal
    end
    #printf "Token #{n} Got, Delay %7.3f ms\n",(Time.now.to_f - time)*1000
  end

  def ensure_token(min,max)
    max = [max,DCB_SDN_MAX_TOKEN_REQ].min
    max = min if max < min
    @token_lock.synchronize do
      while @token < min
        get_min = min - @token
        get_max = max - @token 
        get_token(get_min,get_max)
      end
    end
  end

  def get_token(min,max)
    call_time = Time.now
    @token_getter.get_token(self,min,max)
    #printf("Token Delay: %7.3f ms\n",(Time.now - call_time)*1000) if @pkt_buf.active
  end

  def restore_token(n)
    @token_getter.restore_token(self,n)
  end


  def connection_data_reset
    @block_buf = []
    @wait_for_packet = false
    @recv_buff = [false]*CLI_ACK_SLICE_PKT
    @recv_count = 0
    @task_cnt = 0

  end

  def end_connection
    connection_data_reset
    @pkt_buf.end_connection(@port)
  end

  def run_loop
    raise RuntimeError,"No loop defined"
  end

  def execute_buffer
    block_buf = @pkt_buf.extract_block(@port)
    block_buf.each do |pkt|
      process_packet(pkt)
    end
  end

  def extract_next_packet(timeout = nil)
    # process data in block
    if @block_buf.empty?
      @block_buf = @pkt_buf.extract_block(@port,timeout)
      if !@block_buf.empty?
        #puts "#{@port} Extracted block#: #{@block_buf.size}"
        #sleep (rand(3)+1)*0.0001
      else
        #sleep 0.1
      end
    end
    if !@block_buf.empty?
      #puts "buffer remain:#{@block_buf.size}"
      return @block_buf.shift
    else
      return nil
    end
  end

  def write_packet_req(req,*peer)
    @pkt_buf.write_packet_req(@port,req,*peer)
  end
  def write_packet_raw(str,*peer)
    @pkt_buf.write_packet_raw(@port,str,*peer)
  end

  def cleanup
    @lock_file.flock(File::LOCK_UN)
  end
  
  def send_and_wait_for_ack(ack_req,*peer)
    str = pack_command(ack_req)
    sz = write_packet_raw(str,*peer)
    # Restore writing size
    @pkt_buf.total_tx[@port] -= sz if !TRAFFIC_COUNT_ACK
    if DCB_SENDER_REQUIRE_ACK
      loop do
        # get next
        pkt = extract_next_packet(5)
        if pkt && pkt[:req][:is_reply] && pkt[:req][:type] == ack_req[:type]
          #puts "收到ACK reply"
          @pkt_buf.total_rx[@port] -= pkt[:size] if !TRAFFIC_COUNT_ACK
          return pkt[:req]
        else
          # Timedout
          puts "重新傳輸 #{ack_req[:type]} request"
          ensure_token(1,1)
          @token -= 1
          sz = write_packet_raw(str,*peer)
          # Restore writing size
          @pkt_buf.total_tx[@port] -= sz if !TRAFFIC_COUNT_ACK
        end
      end
    end
  end

end

class PassivePacketHandler < PacketHandler
  def initialize(pkt_buf,peer_ip,port)
    super
  end
 
  def run_send_loop(pkt)
    # Write back ack right now
    ack_req = pkt[:req]
    peer = pkt[:peer]
    io_type = ack_req[:extra].to_i
    # Compute pkt count
    pkt_cnt = (ack_req[:data_size].to_f / PACKET_SIZE ).ceil
    if DCB_SENDER_REQUIRE_ACK
      sub_size = get_sub_size(io_type)
      ack_req[:sub_size] = sub_size
      # Reply Ack
      req_to_reply(ack_req)
      ensure_token(1,1)
      @token -= 1
      sz = write_packet_req(ack_req,*peer)
      if !TRAFFIC_COUNT_ACK
        @pkt_buf.total_tx[@port] -= sz
      end
    else
      sub_size = pkt_cnt
    end
    # Prepare
    i = 0
    done = false
    stop = false
    # ACK Req
    ack_req = {}
    ack_req[:is_request] = true
    ack_req[:type] = "recv ack"
    last_time = Time.now
    # Data Req
    data_req = {}
    data_req[:is_request] = true
    data_req[:type] = "recv data"
    loop do # send loop
      current_send = 0
      # start block
      send_min = [sub_size,pkt_cnt].min
      if DCB_SENDER_REQUIRE_ACK
        min = send_min + DCB_SDN_EXTRA_TOKEN_USED
        ensure_token(min,min)
      else
        remain = send_min
        interval_get = (remain / 10.0).ceil
        this_get = [interval_get,DCB_SDN_MAX_TOKEN_REQ,remain].min
        ensure_token(this_get,this_get)
      end
      send_min.times do |j|
        if !DCB_SENDER_REQUIRE_ACK
          if @token <= 0
            this_get = [interval_get,DCB_SDN_MAX_TOKEN_REQ,remain].min
            ensure_token(this_get,this_get)
          end
          @token -= 1
          remain -= 1
        end
        data_req[:task_no] = i
        data_req[:sub_no] = [j]
        current_send += 1
        pkt_cnt -= 1
        current_send += 1
        if pkt_cnt <= 0
          data_req[:extra] = "DONE"
          done = true
        else
          data_req[:extra] = "CONTINUE"
        end
        write_packet_req(data_req,*peer)
      end
      if DCB_SENDER_REQUIRE_ACK
        @token -= send_min
      end
      # send ack
      if DCB_SENDER_REQUIRE_ACK
        @token -= 1
        new_sub_size = get_sub_size(io_type)
        ack_req[:sub_size] = new_sub_size
        reply_req = send_and_wait_for_ack(ack_req,*peer)

        if reply_req[:extra] == "LOSS"
          pkt_cnt += current_send
          @pkt_buf.total_tx[@port] -= current_send * PACKET_SIZE
          @pkt_buf.total_tx_loss[@port] += sub_size
          done = false
        else
          sub_size = new_sub_size
          if done
            stop = true
          end
          i += 1
        end
      else
        if done
          stop = true
        end
        i += 1
      end
      if stop
        restore_token(@token)
        @token = 0
        break
      end
    end

  end

  def run_recv_loop(pkt)
    # Write back ack right now
    ack_req = pkt[:req]
    # IO type
    io_type = ack_req[:extra].to_i
    # Sub size 
    sub_size = ack_req[:sub_size]  
    # Reply Ack
    if DCB_SENDER_REQUIRE_ACK
      req_to_reply(ack_req)
      ensure_token(1,100)
      #ensure_token(1,1)
      @token -= 1
      sz = write_packet_req(ack_req,*pkt[:peer])
      if !TRAFFIC_COUNT_ACK
        @pkt_buf.total_tx[@port] -= sz
      end
    end
    # Prepare
    task_n = 0
    done = false
    loop do # receive loop
      # read block
      got_ack_pkt = nil
      sub_n = 0
      loss = false
      current_read = 0

      # Sub data buffer
      sub_buf = [false] * sub_size
      #puts "READ SUB SIZE: #{sub_size}"
      while sub_n < sub_size
        data_pkt = extract_next_packet
        current_read += data_pkt[:size]
        data_req = data_pkt[:req]
        if data_req[:type] != "send data"
          if data_req[:type] == "send ack"
            puts "提早收到ACK，#{sub_n}/#{sub_size}"
            got_ack_pkt = data_pkt
            #@pkt_buf.total_rx_loss[@port] += CLI_ACK_SLICE_PKT - 1 - sub_n
            loss = true
            break
          else
            puts "收到預期外封包" 
          end
        end
        if data_req[:task_no] != task_n
          #puts "Task預期：#{task_n}，收到：#{data_req[:task_no]}"
          #@pkt_buf.total_rx_loss[@port] += CLI_ACK_SLICE_PKT 
          loss = true
          break
        end
        data_sub_n = data_req[:sub_no][0] 
        sub_buf[data_sub_n] = true
        sub_n += 1
        # Check Done
        if data_req[:extra] == "DONE"
          #puts "DATA DONE"
          for i in sub_n...sub_size
            sub_buf[i] = true
          end
          done = true
          break
        else
          done = false
        end
      end
      # 檢查sub buf 
      if sub_buf.all? {|v| v } && ( SERVER_LOSS_RATE == 0.0 || rand > SERVER_LOSS_RATE )
        # 全都有
      else
        loss = true
      end
      # read ack 
      if DCB_SENDER_REQUIRE_ACK
        # read until an ack appear
        #first = true
        begin
          #@pkt_buf.total_rx[@port] -= PACKET_SIZE if !first
          #first = false
          if got_ack_pkt
            data_ack_pkt = got_ack_pkt
            got_ack_pkt = nil
          else
            data_ack_pkt = extract_next_packet
            current_read += data_ack_pkt[:size]
          end
          data_ack_req = data_ack_pkt[:req]
          #puts "ACK：收到：#{data_ack_req}"
        end while !(data_ack_req[:is_request] && data_ack_req[:type] == "send ack")
        # ACK traffic count
        if !got_ack_pkt && !TRAFFIC_COUNT_ACK
          @pkt_buf.total_rx[@port] -= PACKET_SIZE
        end
        current_read -= PACKET_SIZE
        # send ack back
        req_to_reply(data_ack_req)
        new_sub_size = data_ack_req[:sub_size]
        if loss
          @pkt_buf.total_rx[@port] -= current_read
          @pkt_buf.total_rx_loss[@port] += sub_size
          data_ack_req[:extra] = "LOSS"
        else
          data_ack_req[:extra] = "OK"
          task_n += 1
          io_time = get_disk_io_time(io_type)
          #printf "IO Time: %7.5f\n",io_time
          sleep io_time
          sub_size = new_sub_size
        end
        ensure_token(1,100)
        @token -= 1
        write_packet_req(data_ack_req,*data_ack_pkt[:peer])
        if !TRAFFIC_COUNT_ACK
          @pkt_buf.total_tx[@port] -= sz
        end
      end
      if !loss && done
        restore_token(@token)
        @token = 0
        #puts "DONE"
        break
      end
    end
  end


  def run_loop
    loop do
      pkt = extract_next_packet
      if pkt
        if !TRAFFIC_COUNT_ACK
          @pkt_buf.total_rx[@port] -= pkt[:size]
        end
        if pkt[:req][:is_request] && pkt[:req][:type] == "send init"
          run_recv_loop(pkt)
        elsif pkt[:req][:is_request] && pkt[:req][:type] == "recv init"
          run_send_loop(pkt)
        end
      end
    end
  end
  
end

class ActivePacketHandler < PacketHandler


  def initialize(pkt_buf,peer_ip,port,total_send,io_type)
    super(pkt_buf,peer_ip,port)
    @stop = false
    @total_send = total_send
    @io_type = io_type
  end

  def run_loop(type)
    case type
    when "read"
      run_recv_loop
    when "write"
      run_send_loop
    end
  end

  def run_recv_loop
    # Send Init request
    init_req = {}
    init_req[:is_request] = true
    init_req[:type] = "recv init"
    init_req[:data_size] = @total_send
    init_req[:extra] = @io_type
    rep = send_and_wait_for_ack(init_req)
    if DCB_SENDER_REQUIRE_ACK
      sub_size = rep[:sub_size]
      ensure_token(1,1)
    else
      sub_size = (@total_send.to_f / PACKET_SIZE ).ceil
    end
    task_n = 0
    accu = @total_send
    # Recv loop
    loop do
      # read block
      got_ack_pkt = nil
      sub_n = 0
      loss = false
      current_read = 0

      # Sub data buffer
      sub_buf = [false] * sub_size

      while sub_n < sub_size
        data_pkt = extract_next_packet
        current_read += data_pkt[:size]
        data_req = data_pkt[:req]
        if data_req[:type] != "recv data"
          if data_req[:type] == "recv ack"
            #puts "提早收到ACK"
            got_ack_pkt = data_pkt
            #@pkt_buf.total_rx_loss[@port] += CLI_ACK_SLICE_PKT - 1 - sub_n
            loss = true
            break
          else
            puts data_req
            puts "收到預期外封包" 
          end
        end
        if data_req[:task_no] != task_n
          #puts "Task預期：#{task_n}，收到：#{data_req[:task_no]}"
          #@pkt_buf.total_rx_loss[@port] += CLI_ACK_SLICE_PKT 
          loss = true
          break
        end
        data_sub_n = data_req[:sub_no][0] 
        sub_buf[data_sub_n] = true
        sub_n += 1
        # Check Done
        if data_req[:extra] == "DONE"
          #puts "DATA DONE"
          for i in sub_n...sub_size
            sub_buf[i] = true
          end
          done = true
          break
        else
          done = false
        end
        if !DCB_SENDER_REQUIRE_ACK
          accu -= PACKET_SIZE
          puts "#{sub_n}/#{sub_size}  剩餘：#{accu}"
        end
      end
      # 檢查sub buf 
      if sub_buf.all? {|v| v } && ( CLIENT_LOSS_RATE == 0.0 || rand > CLIENT_LOSS_RATE )
        # 全都有
      else
        loss = true
      end
      # read ack 
      if DCB_SENDER_REQUIRE_ACK
        # read until an ack appear
        begin
          if got_ack_pkt
            data_ack_pkt = got_ack_pkt
            got_ack_pkt = nil
          else
            data_ack_pkt = extract_next_packet
            current_read += data_ack_pkt[:size]
          end
          data_ack_req = data_ack_pkt[:req]
          #puts "ACK：收到：#{data_ack_req}"
        end while !(data_ack_req[:is_request] && data_ack_req[:type] == "recv ack")
        # ACK traffic count
        if !got_ack_pkt && !TRAFFIC_COUNT_ACK
          @pkt_buf.total_rx[@port] -= PACKET_SIZE
        end
        current_read -= PACKET_SIZE
        # send ack back
        req_to_reply(data_ack_req)
        if loss
          data_ack_req[:extra] = "LOSS"
        else
          data_ack_req[:extra] = "OK"
          task_n += 1
          io_time = get_disk_io_time(@io_type)
          #printf "IO Time: %7.5f\n",io_time
          sleep io_time
          sub_size = data_ack_req[:sub_size]
        end
        ensure_token(1,1)
        @token -= 1
        #puts "Reply ACK：#{data_ack_req}"
        write_packet_req(data_ack_req)
      end
      if !loss && done
        restore_token(@token)
        puts "DONE"
        Process.kill("INT",Process.pid)
        break
      end


    end

  end

  def run_send_loop
    i = 0
    ack_req = {}
    ack_req[:is_request] = true
    ack_req[:type] = "send ack"
    last_time = Time.now
    # Sub size
    if DCB_SENDER_REQUIRE_ACK
      sub_size = get_sub_size(@io_type)
    else
      sub_size = (@total_send.to_f / PACKET_SIZE ).ceil
    end
    # Data Req
    data_req = {}
    data_req[:is_request] = true
    data_req[:type] = "send data"
    # Send Init request
    init_req = {}
    init_req[:is_request] = true
    init_req[:type] = "send init"
    init_req[:data_size] = @total_send
    init_req[:sub_size] = sub_size
    init_req[:extra] = @io_type
    ensure_token(1,1)
    send_and_wait_for_ack(init_req)
    @token -= 1
    # Start Data Packet
    timing = Timing.new
    loop do
      current_send = 0
      last_time = Time.now
      #puts "Delay: #{timing.end}"
      timing.start
      done = false
      if DCB_SENDER_REQUIRE_ACK
        min = sub_size +  DCB_SDN_EXTRA_TOKEN_USED
        if min < 100
          max = 100
        else
          max = min
        end
        ensure_token(min,max)
      else
        remain = sub_size
        interval_get = (sub_size / 10.0).ceil
        this_get = [interval_get,DCB_SDN_MAX_TOKEN_REQ,remain].min
        ensure_token(this_get,this_get)
      end
      #puts "Token : #{timing.check}"
      sub_size.times do |j|
        if !DCB_SENDER_REQUIRE_ACK
          if @token <= 0
            this_get = [interval_get,DCB_SDN_MAX_TOKEN_REQ,remain].min
            ensure_token(this_get,this_get)
          end
          @token -= 1
          remain -= 1
        end
        data_req[:task_no] = i
        data_req[:sub_no] = [j]
        @total_send -= PACKET_SIZE
        current_send += PACKET_SIZE
        if @total_send <= 0
          data_req[:extra] = "DONE"
          done = true
        else
          data_req[:extra] = "CONTINUE"
        end
        write_packet_req(data_req)
        if done
          #puts "pre-DONE"
          @token += sub_size - 1 - j
          break
        end
      end
      #puts "Batch: #{timing.check}"
      if DCB_SENDER_REQUIRE_ACK
        @token -= sub_size
      end
      if DCB_SENDER_REQUIRE_ACK
        new_sub_size = get_sub_size(@io_type)
        ack_req[:sub_size] = new_sub_size
        @token -= 1
        ack_timing = Timing.new
        reply_req = send_and_wait_for_ack(ack_req)
        #puts "ACK Delay: #{ack_timing.end}"
        if reply_req[:extra] == "LOSS"
          @total_send += current_send
          done = false
        else
          sub_size = new_sub_size
          if done
            @stop = true
          end
          i += 1
        end
      else
        if done
          @stop = true
        end
        i += 1
      end
      if @stop
        restore_token(@token)
        cleanup
        Process.kill("INT",Process.pid)
        break
      end
      #puts "ACK: #{timing.end}"
    end
  end

  

  def execute_next_action
  end

  def cleanup
    super
  end
end

