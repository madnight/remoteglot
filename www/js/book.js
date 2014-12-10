(function() {

var board = null;
var moves = [];
var move_override = 0;

var get_game = function() {
	var game = new Chess();
	for (var i = 0; i < move_override; ++i) {
		game.move(moves[i]);
	}
	return game;
}

var update = function() {
	var game = get_game();
	board.position(game.fen());
	fetch_analysis();
}

var fetch_analysis = function() {
	var game = get_game();
	$.ajax({
		url: "/opening-stats.pl?fen=" + encodeURIComponent(game.fen())
	}).done(function(data, textstatus, xhr) {
		show_lines(data, game);
	});
}

var add_td = function(tr, value) {
	var td = document.createElement("td");
	tr.appendChild(td);
	$(td).addClass("num");
	$(td).text(value);
}

var TYPE_MOVE = 0;
var TYPE_INTEGER = 1;
var TYPE_FLOAT = 2;
var TYPE_RATIO = 3;

var headings = [
	[ "Move", TYPE_MOVE ],
	[ "Games", TYPE_INTEGER ],
	[ "%", TYPE_RATIO ],
	[ "Win%", TYPE_RATIO ],
	[ "WWin", TYPE_INTEGER ],
	[ "%WW", TYPE_RATIO ],
	[ "Bwin", TYPE_INTEGER ],
	[ "%BW", TYPE_RATIO ],
	[ "Draw", TYPE_INTEGER ],
	[ "Draw%", TYPE_RATIO ],
	[ "AvWElo", TYPE_FLOAT ],
	[ "AvBElo", TYPE_FLOAT ],
	[ "EloVar", TYPE_FLOAT ],
	[ "AWin%", TYPE_RATIO ],
];

var show_lines = function(data, game) {
	var moves = data['moves'];
	$('#numviewers').text(data['opening']);
	var total_num = 0;
	for (var i = 0; i < moves.length; ++i) {
		var move = moves[i];
		total_num += parseInt(move['white']);
		total_num += parseInt(move['draw']);
		total_num += parseInt(move['black']);
	}

	var headings_tr = $("#headings");
	headings_tr.empty();
	for (var i = 0; i < headings.length; ++i) {
		var th = document.createElement("th");
		headings_tr.append(th);
		$(th).text(headings[i][0]);
	}

	var lines = [];
	for (var i = 0; i < moves.length; ++i) {
		var move = moves[i];
		var line = [];

		var white = parseInt(move['white']);
		var draw = parseInt(move['draw']);
		var black = parseInt(move['black']);

		line.push(move['move']);  // Move.
		var num = white + draw + black;
		line.push(num);  // N.
		line.push(num / total_num);  // %.

		// Win%.
		var white_win_ratio = (white + 0.5 * draw) / num;
		var win_ratio = (game.turn() == 'w') ? white_win_ratio : 1.0 - white_win_ratio;
		line.push(win_ratio);

		line.push(white);        // WWin.
		line.push(white / num);  // %WW.
		line.push(black);        // BWin.
		line.push(black / num);  // %BW.
		line.push(draw);         // Draw.
		line.push(draw / num);   // %Draw.

		if (move['num_elo'] >= 10) {
			// Elo.
			line.push(move['white_avg_elo']);
			line.push(move['black_avg_elo']);
			line.push(move['white_avg_elo'] - move['black_avg_elo']);

			// Win% corrected for Elo.
			var win_elo = -400.0 * Math.log(1.0 / white_win_ratio - 1.0) / Math.LN10;
			win_elo -= (move['white_avg_elo'] - move['black_avg_elo']);
			white_win_ratio = 1.0 / (1.0 + Math.pow(10, win_elo / -400.0));
			win_ratio = (game.turn() == 'w') ? white_win_ratio : 1.0 - white_win_ratio;
			line.push(win_ratio);
		} else {
			line.push(null);
			line.push(null);
			line.push(null);
			line.push(null);
		}
		lines.push(line);
	}

	var tbl = $("#lines");
	tbl.empty();

	for (var i = 0; i < moves.length; ++i) {
		var line = lines[i];
		var tr = document.createElement("tr");

		for (var j = 0; j < line.length; ++j) {
			if (line[j] === null) {
				add_td(tr, "");
			} else if (headings[j][1] == TYPE_MOVE) {
				var td = document.createElement("td");
				tr.appendChild(td);
				$(td).addClass("move");
				var move_a = document.createElement("a");
				move_a.href = "javascript:make_move('" + line[j] + "')";
				td.appendChild(move_a);
				$(move_a).text(line[j]);
			} else if (headings[j][1] == TYPE_INTEGER) {
				add_td(tr, line[j]);
			} else if (headings[j][1] == TYPE_FLOAT) {
				add_td(tr, line[j].toFixed(1));
			} else {
				add_td(tr, (100.0 * line[j]).toFixed(1) + "%");
			}
		}

		tbl.append(tr);
	}
}

var make_move = function(move) {
	moves.length = move_override;
	moves.push(move);
	move_override = moves.length;
	update();
}
window['make_move'] = make_move;

var prev_move = function() {
	if (move_override > 0) {
		--move_override;
		update();
	}
}
window['prev_move'] = prev_move;

var next_move = function() {
	if (move_override < moves.length) {
		++move_override;
		update();
	}
}
window['next_move'] = next_move;

// almost all of this stuff comes from the chessboard.js example page
var onDragStart = function(source, piece, position, orientation) {
	var game = get_game();
	if (game.game_over() === true ||
	    (game.turn() === 'w' && piece.search(/^b/) !== -1) ||
	    (game.turn() === 'b' && piece.search(/^w/) !== -1)) {
		return false;
	}
}

var onDrop = function(source, target) {
	// see if the move is legal
	var game = get_game();
	var move = game.move({
		from: source,
		to: target,
		promotion: 'q' // NOTE: always promote to a queen for example simplicity
	});

	// illegal move
	if (move === null) return 'snapback';

	moves = game.history({ verbose: true });
	move_override = moves.length;
};

// update the board position after the piece snap 
// for castling, en passant, pawn promotion
var onSnapEnd = function() {
	var game = get_game();
	board.position(game.fen());
	fetch_analysis();
};

var init = function() {
	// Create board.
	board = new window.ChessBoard('board', {
		draggable: true,
		position: 'start',
		onDragStart: onDragStart,
		onDrop: onDrop,
		onSnapEnd: onSnapEnd
	});
	update();

	$(window).keyup(function(event) {
		if (event.which == 39) {
			next_move();
		} else if (event.which == 37) {
			prev_move();
		}
	});
}


$(document).ready(init);

})();
