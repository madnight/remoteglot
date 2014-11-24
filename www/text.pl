#! /usr/bin/perl
use CGI;
print CGI->header(-type=>'text/plain', -refresh=>'5; http://analysis.sesse.net/text.pl', -expires=>'+5s');
# print CGI->header(-type=>'text/plain');
open(my $fh, "tail -100 /home/remoteglot/log.txt |");
my @lines = ();
while (<$fh>) {
	s/.*H.*2J.*Analysis/Analysis/;
	if (/^Analysis/) { @lines = (); }
	push @lines, $_;
}
print join('', @lines);
#system("tail -100 /home/remoteglot/log.txt | grep -A 8 Analysis | sed 's/^.*Analysis/Analysis/'");
if (-r "/srv/analysis.sesse.net/complete_analysis.txt") {
#	system("cat /srv/analysis.sesse.net/complete_analysis.txt");
}
