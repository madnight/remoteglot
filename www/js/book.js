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

	var tbl = $("#lines");
	tbl.empty();

	for (var i = 0; i < moves.length; ++i) {
		var move = moves[i];
		var tr = document.createElement("tr");

		var white = parseInt(move['white']);
		var draw = parseInt(move['draw']);
		var black = parseInt(move['black']);

		// Move.
		var move_td = document.createElement("td");
		tr.appendChild(move_td);
		$(move_td).addClass("move");

		var move_a = document.createElement("a");
		move_a.href = "javascript:make_move('" + move['move'] + "')";
		move_td.appendChild(move_a);
		$(move_a).text(move['move']);

		// N.
		var num = white + draw + black;
		add_td(tr, num);

		// %.
		add_td(tr, (100.0 * num / total_num).toFixed(1) + "%");

		// Win%.
		var white_win_ratio = (white + 0.5 * draw) / num;
		var win_ratio = (game.turn() == 'w') ? white_win_ratio : 1.0 - white_win_ratio;
		add_td(tr, ((100.0 * win_ratio).toFixed(1) + "%"));

		// WWin and %WW.
		add_td(tr, white);
		add_td(tr, (100.0 * white / num).toFixed(1) + "%");

		// BWin and %BW.
		add_td(tr, black);
		add_td(tr, (100.0 * black / num).toFixed(1) + "%");

		// Draw and %Draw.
		add_td(tr, draw);
		add_td(tr, ((100.0 * draw / num).toFixed(1) + "%"));

		if (move['num_elo'] >= 10) {
			// Elo.
			add_td(tr, move['white_avg_elo'].toFixed(1));
			add_td(tr, move['black_avg_elo'].toFixed(1));
			add_td(tr, (move['white_avg_elo'] - move['black_avg_elo']).toFixed(1));

			// Win% corrected for Elo.
			var win_elo = -400.0 * Math.log(1.0 / white_win_ratio - 1.0) / Math.LN10;
			win_elo -= (move['white_avg_elo'] - move['black_avg_elo']);
			white_win_ratio = 1.0 / (1.0 + Math.pow(10, win_elo / -400.0));
			win_ratio = (game.turn() == 'w') ? white_win_ratio : 1.0 - white_win_ratio;
			add_td(tr, ((100.0 * win_ratio).toFixed(1) + "%"));
		} else {
			add_td(tr, "");
			add_td(tr, "");
			add_td(tr, "");
			add_td(tr, "");
		}

		if (false) {
			// Win bars (W/D/B).
			var winbar_td = document.createElement("td");
			$(winbar_td).addClass("winbars");
			tr.appendChild(winbar_td);
			var winbar_table = document.createElement("table");
			winbar_td.appendChild(winbar_table);
			var winbar_tr = document.createElement("tr");
			winbar_table.appendChild(winbar_tr);

			if (white > 0) {
				var white_percent = (100.0 * white / num).toFixed(0) + "%";
				var white_td = document.createElement("td");
				winbar_tr.appendChild(white_td);
				$(white_td).addClass("white");
				white_td.style.width = white_percent;
				$(white_td).text(white_percent);
			}
			if (draw > 0) {
				var draw_percent = (100.0 * draw / num).toFixed(0) + "%";
				var draw_td = document.createElement("td");
				winbar_tr.appendChild(draw_td);
				$(draw_td).addClass("draw");
				draw_td.style.width = draw_percent;
				$(draw_td).text(draw_percent);
			}
			if (black > 0) {
				var black_percent = (100.0 * black / num).toFixed(0) + "%";
				var black_td = document.createElement("td");
				winbar_tr.appendChild(black_td);
				$(black_td).addClass("black");
				black_td.style.width = black_percent;
				$(black_td).text(black_percent);
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
