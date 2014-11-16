# Default configuration. Copy this file to config.local.pm if you want
# to change anything instead of modifying this (so you won't have to make
# changes in git).

package remoteglotconf;

our $server = "freechess.org";
our $nick = "SesseBOT";
our $target = "GMCarlsen";  # FICS username or HTTP to a PGN file.
our $json_output = "/srv/analysis.sesse.net/www/analysis.json";

our $engine_cmdline = "./stockfish";
our %engine_config = (
# 	'NalimovPath' => '/srv/tablebase',
	'NalimovUsage' => 'Rarely',
	'Hash' => '1024',
#	'MultiPV' => '2'
);

# Separate engine for multi-PV; can be undef for none.
our $engine2_cmdline = undef;
our %engine2_config = (
#	'NalimovPath' => '/srv/tablebase',
	'NalimovUsage' => 'Rarely',
	'Hash' => '1024',
	'Threads' => '8',
);

our $uci_assume_full_compliance = 0;                    # dangerous :-)
our $update_max_interval = 1.0;
our @masters = (
	'Sesse',
);

# ChessOK serial key (of the form NNNNN-NNNNN-NNNNN-NNNNN-NNNNN-NNNNN)
# for looking up 7-man tablebases; undef means no lookup. Note that
# you probably need specific prior permission to use this.
our $tb_serial_key = undef;

eval {
	require 'config.local.pm';
};
