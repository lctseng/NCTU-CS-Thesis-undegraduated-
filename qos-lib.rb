require_relative 'qos-info'

class Hash

  def ensure_key(key,value)
    if !self.has_key?(key)
      self[key] = value
    end
  end
end


def parse_command(str)
  req = {}
  main_type,type,task,sub,data_size,pad = str.split(';')
  # 判斷大類別
  if main_type == "request"
    req[:is_request] = true
  else
    req[:is_request] = false
  end
  req[:is_reply] = !req[:is_request]
  req[:type] = type
  req[:task_no] = task.to_i
  req[:sub_no] = sub.split(',').collect{|s| s.to_i}
  req[:data_size] = data_size.to_i
  req
end

def pack_command(req)
  # fill main type
  if req.has_key? :is_request
    req[:is_reply] = !req[:is_request]
  elsif req.has_key? :is_reply
    req[:is_request] = !req[:is_reply]
  end
  # fill key
  req.ensure_key(:is_request,true)
  req.ensure_key(:is_reply,false)
  req.ensure_key(:type,"noop")
  req.ensure_key(:task_no,0)
  req.ensure_key(:sub_no,[0])
  req.ensure_key(:data_size,0)
  # convert
  main_type = req[:is_request] ? "request" : "reply"
  sub_no = req[:sub_no].join(',')
  info = "#{main_type};#{req[:type]};#{req[:task_no]};#{sub_no};#{req[:data_size]};"
  pad = '1' * (PACKET_SIZE - info.size)
  return info + pad
end