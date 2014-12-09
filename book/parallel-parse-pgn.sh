#! /bin/sh
FILE=$1
for X in $( seq 0 39 ); do
	( ./parse-pgn.pl $FILE $X 40 >> part-$X.bin ) &
done
wait
