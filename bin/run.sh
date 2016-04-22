#!/bin/sh

SCRIPT=`readlink -f $0`
SCRIPT=${SCRIPT:-$0}
cd ${SCRIPT%/*}

erl -sname a -pa ../ebin -boot ../priv/netmon -config ../etc/sys.config
