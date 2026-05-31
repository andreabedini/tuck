package require tcltest
namespace import ::tcltest::*
configure {*}$argv
configure -testdir [file dirname [info script]]
runAllTests
