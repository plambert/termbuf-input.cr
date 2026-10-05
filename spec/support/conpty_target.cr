# The program the pseudoconsole specs run. Raw mode on, a stream on standard
# input, and one line in the log named as the first argument for every event:
# `ready` once it is reading, then `key Up`, `resize 100x30`, and so on. Ends
# on q.
require "../../src/termbuf-input"

alias Input = TermBuf::Input

log = File.new ARGV[0], "w"
log.sync = true

raw = Input::RawMode.new STDIN, STDOUT
log.puts "console #{!Input::Console.for?(STDIN).nil?}, raw #{raw.enter}"

stream = Input::Stream.new STDIN, blocking: true
stream.start
log.puts "ready"

loop do
  case event = stream.events.receive?
  when Nil, Input::Events::Closed
    break
  when Input::Events::Key
    log.puts "key #{event.key}"
    break if event.key.is? 'q'
  when Input::Events::Resize
    log.puts "resize #{event.size}"
  when Input::Events::Paste
    log.puts "paste #{event.text.inspect}"
  else
    log.puts "event #{event.class.name.split("::").last}"
  end
end

stream.close
raw.leave
log.puts "done"
