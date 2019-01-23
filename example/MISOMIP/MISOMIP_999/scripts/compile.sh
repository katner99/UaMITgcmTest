#!/bin/bash
################################################
# Compile MITgcm.
################################################

# Empty the build directory - but first make sure it exists!
if [ -d "../build" ]; then
  cd ../build
  rm -rf *
else
  echo 'Creating build directory'
  mkdir ../build
  cd ../build
fi

# Generate a Makefile
$ROOTDIR/tools/genmake2 -ieee -mods=../code -of=../../../build_options/linux_amd64_archer_ifort -mpi

# Run the Makefile
make depend
make