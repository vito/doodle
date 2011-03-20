task :parser do
  sh "kpeg -f -s -n Anatomy::Parser lib/anatomy.kpeg"
end

task :clean do
  sh "find . -name '*.rbc' -delete; find . -name '*.atomoc' -delete"
end
