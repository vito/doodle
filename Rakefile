task :parser do
  sh "kpeg -f -s -n Doodle::Parser lib/doodle.kpeg"
end

task :clean do
  sh "find . -name '*.rbc' -delete; find . -name '*.ayc' -delete"
end
