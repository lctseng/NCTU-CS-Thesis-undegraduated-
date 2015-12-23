class PacketHandler

  attr_reader :id
  attr_reader :peer_ip
  attr_reader :port

  attr_reader :token
  attr_reader :lock_file
  attr_accessor :token_getter

  attr_reader :token_lock
  attr_reader :token_ready

  def give_token(n,time)
    @token_lock.synchronize do
      @token += n
      @token_ready.signal
    end
    printf "Token #{n} Got, Delay %7.3f ms\n",(Time.now.to_f - time)*1000
  end

  def ensure_token(min,max)
    @token_lock.synchronize do
      while @token < min
        get_min = min - @token
        get_max = max
        get_token(get_min,get_max)
      end
    end
  end

  def get_token(min,max)
    call_time = Time.now
    @token_getter.get_token(self,min,max)
    #printf("Token Delay: %7.3f ms\n",(Time.now - call_time)*1000)
  end

  #
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
    n = 0
    loop do
      n+= 1
      #puts n
      #execute_buffer
      pkt = extract_next_packet
      if pkt
        process_packet(pkt)
        if @stop
          break
        end
      elsif !@wait_for_packet
        execute_next_action
      end
    end
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

  def execute_next_action
    return nil
  end

  def process_data_packet(pkt)
    task_n = pkt[:req][:task_no]
    if task_n != @task_cnt
      #puts "錯誤的大編號：#{task_n}，預期：#{@task_cnt}"
      CLI_ACK_SLICE_PKT.times do |i|
        @recv_buff[i] = false
      end
      loss = (CLI_ACK_SLICE_PKT - @recv_count  + CLI_ACK_SLICE_PKT * (task_n - @task_cnt - 1))
      @pkt_buf.total_rx_loss[@port] += loss
      @pkt_buf.add_free_token(loss)
      @recv_count = 0
      @task_cnt = task_n
      @lock_file.flock(File::LOCK_UN)
    end
    sub_n = pkt[:req][:sub_no][0]
    #print "收到編號：#{sub_n}，"
    if @recv_buff[sub_n]
      # exist
      #puts "重複封包：#{sub_n}"
    else
      # not exist
      #puts "正確編號：#{sub_n}"
      @recv_buff[sub_n] = true
      @recv_count += 1

      if sub_n == 0
        @lock_file.flock(File::LOCK_EX)
      end
      # full?
      if @recv_count == CLI_ACK_SLICE_PKT
        # full
        CLI_ACK_SLICE_PKT.times do |i|
          @recv_buff[i] = false
        end
        @recv_count = 0
        # IO 
        sleep get_disk_io_time
        @lock_file.flock(File::LOCK_UN)
        if DCB_CEHCK_MAJOR_NUMBER
          @task_cnt += 1
        end
      else
        # not full
      end
    end
  end

  def process_ack_request(pkt)
    #puts "處理ACK request，給：#{pkt[:peer]}"
    req = pkt[:req]
    req[:is_request] = false
    req[:is_reply] = true
    @lock_file.flock(File::LOCK_UN)
    #$pkt_buf.disk_lock.synchronize do
      #sleep 1
    #end
    write_packet_req(req,*(pkt[:peer]))
  end

  def process_packet(pkt)
    #puts pkt[:msg]
    case pkt[:req][:type]
    when "data send"
      process_data_packet(pkt)
    when "data ack"
      process_ack_request(pkt)
    when "end connection"
      end_connection
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

end

class PassivePacketHandler < PacketHandler
  def initialize(pkt_buf,peer_ip,port)
    super
  end
end

class ActivePacketHandler < PacketHandler


  def initialize(pkt_buf,peer_ip,port,total_send)
    super(pkt_buf,peer_ip,port)
    @stop = false
    @total_send = total_send
  end

  def run_loop
    i = 0
    can_get = true
    str = "1"*PACKET_SIZE
    pkts = []
    CLI_ACK_SLICE_PKT.times do |j|
      req = {}
      req[:is_request] = true
      req[:type] = "data send"
      req[:task_no] = i
      req[:sub_no] = [j]
      pkts[j] = pack_command(req)
    end
    last_time = Time.now
    loop do
      #puts "Start #{i} , interval = #{(Time.now - last_time)*1000}ms"
      last_time = Time.now
      #sleep 0.5
      #(rand(100)+1).times do
      min = CLI_ACK_SLICE_PKT + DCB_SDN_EXTRA_TOKEN_USED
      ensure_token(min,min)
      @token -= min
      written = 0
      if DCB_CEHCK_MAJOR_NUMBER
        CLI_ACK_SLICE_PKT.times do |j|
          req = {}
          req[:is_request] = true
          req[:type] = "data send"
          req[:task_no] = i
          req[:sub_no] = [j]
          written += write_packet_req(req)
        end
      else
        CLI_ACK_SLICE_PKT.times do |j|
          written += write_packet_raw(pkts[j])
        end
      end
      
      send_and_wait_for_ack if DCB_SENDER_REQUIRE_ACK
      i += 1
      @total_send -= written
      if @total_send <= 0
        cleanup
        Process.kill("INT",Process.pid)
      end
      if @stop
        end_connection
        break
      end
      #end # end times
      #sleep rand(1) + rand*3
    end
    #sleep rand(1)+rand
  end

  def end_connection
    return if @ended
    @ended = true
    @token_getter.get_token(1,1) 
    req = {}
    req[:is_request] = true
    req[:type] = "end connection"
    #puts "傳輸資料ACK"
    write_packet_req(req)
  end
  
  def write_ack_req
    req = {}
    req[:is_request] = true
    req[:type] = "data ack"
    #puts "傳輸資料ACK"
    write_packet_req(req)
  end

  def send_and_wait_for_ack
    write_ack_req
    loop do
      # get next
      pkt = extract_next_packet(5)
      if pkt && pkt[:req][:type] == "data ack"
        #puts "收到ACK reply"
        break
      else
        # Timedout
        puts "重新傳輸ACK request"
        ensure_token(1,1)
        write_ack_req

      end
    end
  end

  def execute_next_action
  end

  def cleanup
    super
    @stop = true
  end
end

