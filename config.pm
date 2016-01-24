# Default configuration. Copy this file to config.local.pm if you want
# to change anything instead of modifying this (so you won't have to make
# changes in git).

package remoteglotconf;

our $server = "freechess.org";
our $nick = "SesseBOT";
our $target = "GMCarlsen";  # FICS username or HTTP to a PGN file.

# Set to non-undef to pick out one specific game from a PGN file with many games.
# See example.
our $pgn_filter = undef;
#our $pgn_filter = sub {
#	my $pgn = shift;
#	return $pgn->round() eq '7' && $pgn->white eq 'Carlsen,M';
#};

# Set to non-undef to override the clock information with our own calculations.
# The example implements a simple 60+60 (with bonus added before the move).
# FIXME(sesse): We might not see all moves in a PGN individually, so this might
# skip some moves for bonus.
our $adjust_clocks_before_move = undef;
#our $adjust_clocks_before_move = sub {
#        my ($white_clock_left, $black_clock_left, $move, $toplay) = @_;
#
#        if (!defined($$white_clock_left) || !defined($$black_clock_left)) {
#                $$white_clock_left = 3600;
#                $$black_clock_left = 3600;
#        }
#        if ($toplay eq 'W') {
#                $$white_clock_left += 60;
#        } else {
#                $$black_clock_left += 60;
#        }
#};

our $json_output = "/srv/analysis.sesse.net/www/analysis.json";
our $json_history_dir = "/srv/analysis.sesse.net/www/history/";  # undef for none.

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

# Command line to run the Fathom tablebase lookup program, if installed,
# including the --path= argument.
our $fathom_cmdline = undef;

# ChessOK serial key (of the form NNNNN-NNNNN-NNNNN-NNNNN-NNNNN-NNNNN)
# for looking up 7-man tablebases; undef means no lookup. Note that
# you probably need specific prior permission to use this.
our $tb_serial_key = undef;

# Credits to show in the footer.
our $engine_url = "http://www.stockfishchess.org/";
our $engine_details = undef;  # For hardware.
our $move_source = "FICS";
our $move_source_url = "http://www.freechess.org/";

# Postgres configuration.
our $dbistr = "dbi:Pg:dbname=remoteglot";
our $dbiuser = undef;
our $dbipass = undef;

eval {
	my $config_filename = $ENV{'REMOTEGLOT_CONFIG'} // 'config.local.pm';
	require $config_filename;
};
