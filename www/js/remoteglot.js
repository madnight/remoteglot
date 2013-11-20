var board = [];
var arrows = [];
var arrow_targets = [];
var occupied_by_arrows = [];
var ims = 0;
var highlight_from = undefined;
var highlight_to = undefined;
var unique = Math.random();

var request_update = function(board, first) {
	$.ajax({
		url: "http://analysis.sesse.net/analysis.pl?ims=" + ims + "&unique=" + unique
		//url: "http://analysis.sesse.net:5000/analysis.pl?ims=" + ims + "&unique=" + unique
	}).done(function(data, textstatus, xhr) {
		ims = xhr.getResponseHeader('X-Remoteglot-Last-Modified');
		var num_viewers = xhr.getResponseHeader('X-Remoteglot-Num-Viewers');
		update_board(board, data, num_viewers);
	});
}

var clear_arrows = function() {
	for (var i = 0; i < arrows.length; ++i) {
		jsPlumb.detach(arrows[i].connection1);
		jsPlumb.detach(arrows[i].connection2);
	}
	arrows = [];

	for (var i = 0; i < arrow_targets.length; ++i) {
		document.body.removeChild(arrow_targets[i]);
	}
	arrow_targets = [];
	
	occupied_by_arrows = [];	
	for (var y = 0; y < 8; ++y) {
		occupied_by_arrows.push([false, false, false, false, false, false, false, false]);
	}
}

var redraw_arrows = function() {
	for (var i = 0; i < arrows.length; ++i) {
		position_arrow(arrows[i]);
	}
}

var sign = function(x) {
	if (x > 0) {
		return 1;
	} else if (x < 0) {
		return -1;
	} else {
		return 0;
	}
}

// See if drawing this arrow on the board would cause unduly amount of confusion.
var interfering_arrow = function(from, to) {
	var from_col = from.charCodeAt(0) - "a1".charCodeAt(0);
	var from_row = from.charCodeAt(1) - "a1".charCodeAt(1);
	var to_col   = to.charCodeAt(0) - "a1".charCodeAt(0);
	var to_row   = to.charCodeAt(1) - "a1".charCodeAt(1);

	occupied_by_arrows[from_row][from_col] = true;

	// Knight move: Just check that we haven't been at the destination before.
	if ((Math.abs(to_col - from_col) == 2 && Math.abs(to_row - from_row) == 1) ||
	    (Math.abs(to_col - from_col) == 1 && Math.abs(to_row - from_row) == 2)) {
		return occupied_by_arrows[to_row][to_col];
	}

	// Sliding piece: Check if anything except the from-square is seen before.
	var dx = sign(to_col - from_col);
	var dy = sign(to_row - from_row);
	var x = from_col;
	var y = from_row;
	do {
		x += dx;
		y += dy;
		if (occupied_by_arrows[y][x]) {
			return true;
		}
		occupied_by_arrows[y][x] = true;
	} while (x != to_col || y != to_row);

	return false;
}

var add_target = function() {
	var elem = document.createElement("div");
	$(elem).addClass("window");
	elem.id = "target" + arrow_targets.length;
	document.body.appendChild(elem);	
	arrow_targets.push(elem);
	return elem.id;
}
	
var position_arrow = function(arrow) {
	var zoom_factor = $("#board").width() / 400.0;
	var line_width = arrow.line_width * zoom_factor;
	var arrow_size = arrow.arrow_size * zoom_factor;

	var square_width = $(".square-a8").width();
	var from_y = (7 - arrow.from_row + 0.5)*square_width;
	var to_y = (7 - arrow.to_row + 0.5)*square_width;
	var from_x = (arrow.from_col + 0.5)*square_width;
	var to_x = (arrow.to_col + 0.5)*square_width;

	var dx = to_x - from_x;
	var dy = to_y - from_y;
	var len = Math.sqrt(dx * dx + dy * dy);
	dx /= len;
	dy /= len;
	var pos = $(".square-a8").position();
	$("#" + arrow.s1).css({ top: pos.top + from_y + (0.5 * arrow_size) * dy, left: pos.left + from_x + (0.5 * arrow_size) * dx });
	$("#" + arrow.d1).css({ top: pos.top + to_y - (0.5 * arrow_size) * dy, left: pos.left + to_x - (0.5 * arrow_size) * dx });
	$("#" + arrow.s1v).css({ top: pos.top + from_y - 0 * dy, left: pos.left + from_x - 0 * dx });
	$("#" + arrow.d1v).css({ top: pos.top + to_y + 0 * dy, left: pos.left + to_x + 0 * dx });

	if (arrow.connection1) {
		jsPlumb.detach(arrow.connection1);
	}
	if (arrow.connection2) {
		jsPlumb.detach(arrow.connection2);
	}
	arrow.connection1 = jsPlumb.connect({
		source: arrow.s1,
		target: arrow.d1,
		connector:["Straight"],
		cssClass:"c1",
		endpoint:"Blank",
		endpointClass:"c1Endpoint",													   
		anchor:"Continuous",
		paintStyle:{ 
			lineWidth:line_width,
			strokeStyle:arrow.fg_color,
			outlineWidth:1,
			outlineColor:"#666",
			opacity:"60%"
		}
	});
	arrow.connection2 = jsPlumb.connect({
		source: arrow.s1v,
		target: arrow.d1v,
		connector:["Straight"],
		cssClass:"vir",
		endpoint:"Blank",
		endpointClass:"c1Endpoint",													   
		anchor:"Continuous",
		paintStyle:{ 
			lineWidth:0,
			strokeStyle:arrow.fg_color,
			outlineWidth:0,
			outlineColor:"#666",
		},
		overlays : [
			["Arrow", {
				cssClass:"l1arrow",
				location:1.0,
				width: arrow_size,
				length: arrow_size,
				paintStyle: { 
					lineWidth:line_width,
					strokeStyle:"#000",
				},
			}]
		]
	});
}

var create_arrow = function(from_square, to_square, fg_color, line_width, arrow_size) {
	var from_col = from_square.charCodeAt(0) - "a1".charCodeAt(0);
	var from_row = from_square.charCodeAt(1) - "a1".charCodeAt(1);
	var to_col   = to_square.charCodeAt(0) - "a1".charCodeAt(0);
	var to_row   = to_square.charCodeAt(1) - "a1".charCodeAt(1);

	// Create arrow.
	var arrow = {
		s1: add_target(),
		d1: add_target(),
		s1v: add_target(),
		d1v: add_target(),
		from_col: from_col,
		from_row: from_row,
		to_col: to_col,
		to_row: to_row,
		line_width: line_width,
		arrow_size: arrow_size,	
		fg_color: fg_color
	};

	position_arrow(arrow);
	arrows.push(arrow);
}

// Fake multi-PV using the refutation lines. Find all “relevant” moves,
// sorted by quality, descending.
var find_nonstupid_moves = function(data, margin) {
	// First of all, if there are any moves that are more than 0.5 ahead of
	// the primary move, the refutation lines are probably bunk, so just
	// kill them all. 
	var best_score = undefined;
	var pv_score = undefined;
	for (var move in data.refutation_lines) {
		var score = parseInt(data.refutation_lines[move].score_sort_key);
		if (move == data.pv_uci[0]) {
			pv_score = score;
		}
		if (best_score === undefined || score > best_score) {
			best_score = score;
		}
		if (!(data.refutation_lines[move].depth >= 8)) {
			return [];
		}
	}

	if (best_score - pv_score > 50) {
		return [];
	}

	// Now find all moves that are within “margin” of the best score.
	// The PV move will always be first.
	var moves = [];
	for (var move in data.refutation_lines) {
		var score = parseInt(data.refutation_lines[move].score_sort_key);
		if (move != data.pv_uci[0] && best_score - score <= margin) {
			moves.push(move);
		}
	}
	moves = moves.sort(function(a, b) { return parseInt(data.refutation_lines[b].score_sort_key) - parseInt(data.refutation_lines[a].score_sort_key); });
	moves.unshift(data.pv_uci[0]);

	return moves;
}

var thousands = function(x) {
	return String(x).split('').reverse().join('').replace(/(\d{3}\B)/g, '$1,').split('').reverse().join('');
}

var print_pv = function(pretty_pv, move_num, toplay, limit) {
	var pv = '';
	var i = 0;
	if (toplay == 'B') {
		pv = move_num + '. … ' + pretty_pv[0];
		toplay = 'W';
		++i;	
	}
	++move_num;
	for ( ; i < pretty_pv.length; ++i) {
		if (toplay == 'W') {
			if (i > limit) {
				return pv + ' (…)';
			}
			if (pv != '') {
				pv += ' ';
			}
			pv += move_num + '. ' + pretty_pv[i];
			++move_num;
			toplay = 'B';
		} else {
			pv += ' ' + pretty_pv[i];
			toplay = 'W';
		}
	}
	return pv;
}

var compare_by_sort_key = function(data, a, b) {
	var ska = data.refutation_lines[a].sort_key;
	var skb = data.refutation_lines[b].sort_key;
	if (ska < skb) return -1;
	if (ska > skb) return 1;
	return 0;
};
	
var update_highlight = function()  {
	$("#board").find('.square-55d63').removeClass('nonuglyhighlight');
	if (highlight_from !== undefined && highlight_to !== undefined) {
		$("#board").find('.square-' + highlight_from).addClass('nonuglyhighlight');
		$("#board").find('.square-' + highlight_to).addClass('nonuglyhighlight');
	}
}

var update_board = function(board, data, num_viewers) {
	// The headline.
	var headline = 'Analysis';
	if (data.position.last_move !== 'none') {
		headline += ' after ' + data.position.move_num + '. ';
		if (data.position.toplay == 'W') {
			headline += '… ';
		}
		headline += data.position.last_move;
	}

	$("#headline").text(headline);

	if (num_viewers === null) {
		$("#numviewers").text("");
	} else if (num_viewers == 1) {
		$("#numviewers").text("You are the only current viewer");
	} else {
		$("#numviewers").text(num_viewers + " current viewers");
	}

	// The score.
	if (data.score !== null) {
		$("#score").text(data.score);
	}

	// The search stats.
	if (data.nodes && data.nps && data.depth) {
		var stats = thousands(data.nodes) + ' nodes, ' + thousands(data.nps) + ' nodes/sec, depth ' + data.depth + ' ply';
		if (data.seldepth) {
			stats += ' (' + data.seldepth + ' selective)';
		}
		if (data.tbhits && data.tbhits > 0) {
			if (data.tbhits == 1) {
				stats += ', one Nalimov hit';
			} else {
				stats += ', ' + data.tbhits + ' Nalimov hits';
			}
		}
		

		$("#searchstats").text(stats);
	}

	// Update the board itself.
	board.position(data.position.fen);

	if (data.position.last_move_uci) {
		highlight_from = data.position.last_move_uci.substr(0, 2);
		highlight_to = data.position.last_move_uci.substr(2, 4);
	} else {
		highlight_from = highlight_to = undefined;
	}
	update_highlight();

	// Print the PV.
	var pv = print_pv(data.pv_pretty, data.position.move_num, data.position.toplay);
	$("#pv").text(pv);

	// Update the PV arrow.
	clear_arrows();
	if (data.pv_uci.length >= 1) {
		// draw a continuation arrow as long as it's the same piece
		for (var i = 0; i < data.pv_uci.length; i += 2) {
			var from = data.pv_uci[i].substr(0, 2);
			var to = data.pv_uci[i].substr(2,4);
			if ((i >= 2 && from != data.pv_uci[i - 2].substr(2, 4)) ||
			     interfering_arrow(from, to)) {
				break;
			}
			create_arrow(from, to, '#f66', 6, 20);
		}

		var alt_moves = find_nonstupid_moves(data, 30);
		for (var i = 1; i < alt_moves.length && i < 3; ++i) {
			create_arrow(alt_moves[i].substr(0, 2),
				     alt_moves[i].substr(2, 4), '#f66', 1, 10);
		}
	}

	// See if all semi-reasonable moves have only one possible response.
	if (data.pv_uci.length >= 2) {
		var nonstupid_moves = find_nonstupid_moves(data, 300);
		var response = data.pv_uci[1];
		for (var i = 0; i < nonstupid_moves.length; ++i) {
			if (nonstupid_moves[i] == data.pv_uci[0]) {
				// ignore the PV move for refutation lines.
				continue;
			}
			if (!data.refutation_lines ||
			    !data.refutation_lines[nonstupid_moves[i]] ||
			    !data.refutation_lines[nonstupid_moves[i]].pv_uci ||
			    data.refutation_lines[nonstupid_moves[i]].pv_uci.length < 1) {
				// Incomplete PV, abort.
				response = undefined;
				break;
			}
			var this_response = data.refutation_lines[nonstupid_moves[i]].pv_uci[1];
			if (response !== this_response) {
				// Different response depending on lines, abort.
				response = undefined;
				break;
			}
		}

		if (nonstupid_moves.length > 0 && response !== undefined) {
			create_arrow(response.substr(0, 2),
				     response.substr(2, 4), '#66f', 6, 20);
		}
	}

	// Show the refutation lines.
	var tbl = $("#refutationlines");
	tbl.empty();

	moves = [];
	for (var move in data.refutation_lines) {
		moves.push(move);
	}
	moves = moves.sort(function(a, b) { return compare_by_sort_key(data, a, b) });
	for (var i = 0; i < moves.length; ++i) {
		var line = data.refutation_lines[moves[i]];

		var tr = document.createElement("tr");

		var move_td = document.createElement("td");
		tr.appendChild(move_td);
		$(move_td).addClass("move");
		$(move_td).text(line.pretty_move);

		var score_td = document.createElement("td");
		tr.appendChild(score_td);
		$(score_td).addClass("score");
		$(score_td).text(line.pretty_score);

		var depth_td = document.createElement("td");
		tr.appendChild(depth_td);
		$(depth_td).addClass("depth");
		$(depth_td).text("d" + line.depth);

		var pv_td = document.createElement("td");
		tr.appendChild(pv_td);
		$(pv_td).addClass("pv");
		$(pv_td).text(print_pv(line.pv_pretty, data.position.move_num, data.position.toplay, 10));

		tbl.append(tr);
	}

	// Next update.
	setTimeout(function() { request_update(board, 0); }, 100);
}

var init = function() {
	// Create board.
	board = new ChessBoard('board', 'start');

	request_update(board, 1);
	$(window).resize(function() {
		board.resize();
		update_highlight();
		redraw_arrows();
	});
};
$(document).ready(init);
