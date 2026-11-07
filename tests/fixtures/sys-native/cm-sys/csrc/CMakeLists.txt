cmake_minimum_required(VERSION 3.10)
project(cm C)
add_library(cm STATIC cm.c)
install(TARGETS cm ARCHIVE DESTINATION lib)
