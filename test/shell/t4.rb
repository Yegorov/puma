system "rm test/log.log*"

system "ruby -rrubygems -Ilib bin/pumactl -F test/shell/t4_conf.rb start"
sleep 5

def get_worker_pid
  `ps aux | grep puma | grep worker | grep -v grep`.split[1]
end
worker_pid = get_worker_pid()

system "curl http://localhost:10104"
system "mv test/log.log test/log.log.1"
system "kill -HUP `cat t4-pid`"
sleep 8

system "echo 'exec request 8s'"
system "curl http://localhost:10104"
sleep 1

def cleanup
  system "rm test/log.log*"
  system "rm t4-stdout"
  system "rm t4-stderr"
  system "rm t4-pid"
end

new_pid = get_worker_pid()

system "ruby -rrubygems -Ilib bin/pumactl -F test/shell/t4_conf.rb stop"
if new_pid != worker_pid
  puts "worker pid changed from #{worker_pid} to #{new_pid}"
  cleanup
  exit 1
end

if File.size("test/log.log") == 0
  cleanup
  puts "nothing written to reopened log file"
  exit 1
end

cleanup
exit 0
