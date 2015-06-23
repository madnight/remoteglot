#! /usr/bin/perl

# To ingest old data into the database.

use strict;
use warnings;
use DBI;
use DBD::Pg;
use JSON::XS;
use Tie::Persistent;

my $dbh = DBI->connect('dbi:Pg:dbname=remoteglot');
$dbh->{AutoCommit} = 0;
$dbh->{RaiseError} = 1;

# Import positions from history.
for my $filename (<www/history/*.json>) {
	$filename =~ m#www/history/(.*)\.json#;
	my $id = $1;
	print "Analysis: $id...\n";

	my $contents;
	{
		local $/ = undef;
		open my $fh, "<", $filename
			or die "$filename: $!";
		$contents = <$fh>;
		close $fh;
	}

	#$dbh->do('INSERT INTO analysis VALUES (?)', undef, $contents);

	my $json = JSON::XS::decode_json($contents);
	if (defined($json->{'plot_score'})) {	
                my $engine = $json->{'id'}{'name'} // die;
                my $depth = $json->{'depth'} // 0;
                my $nodes = $json->{'nodes'} // 0;

		$dbh->do('DELETE FROM scores WHERE id=?', undef, $id);
		$dbh->do('INSERT INTO scores (id, plot_score, short_score, engine, depth, nodes) VALUES (?, ?, ?, ?, ?, ?)',
			undef, $id, $json->{'plot_score'}, $json->{'short_score'}, $engine, $depth, $nodes);
	}
}

# Import clock information.
tie my %clock_info_for_pos, 'Tie::Persistent', 'clock_info.db', 'rw';

while (my ($id, $clock_info) = each %clock_info_for_pos) {
	print "Clock: $id...\n";
	$dbh->do('DELETE FROM clock_info WHERE id=?', undef, $id);
	$dbh->do('INSERT INTO clock_info (id, white_clock, black_clock, white_clock_target, black_clock_target) VALUES (?, ?, ?, ?, ?)',
		undef, $id, $clock_info->{'white_clock'}, $clock_info->{'black_clock'},
		$clock_info->{'white_clock_target'}, $clock_info->{'black_clock_target'});
}

$dbh->commit;

