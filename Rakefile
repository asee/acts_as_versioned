require 'rubygems'  
require 'rake'  
require 'echoe'  
  
Echoe.new('acts_as_versioned', '3.2.1') do |p|  
  p.description     = "Active Record model versioning"  
  p.url             = "http://github.com/asee/acts_as_versioned"  
  p.author          = "ASEE"  
  p.email           = "it@asee.org"
  p.dependencies = ['activerecord']  
end  
  
Dir["#{File.dirname(__FILE__)}/tasks/*.rake"].sort.each { |ext| load ext }  


#############################################################################
#
# Standard tasks
#
#############################################################################

task :default => :test

require 'rake/testtask'
Rake::TestTask.new(:test) do |test|
  test.libs << 'lib' << 'test'
  test.pattern = 'test/**/*_test.rb'
  test.verbose = true
end

desc "Generate RCov test coverage and open in your browser"
task :coverage do
  require 'rcov'
  sh "rm -fr coverage"
  sh "rcov test/test_*.rb"
  sh "open coverage/index.html"
end

desc "Open an irb session preloaded with this library"
task :console do
  sh "irb -rubygems -r ./lib/#{name}.rb"
end
