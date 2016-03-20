(function() {

/**
 * Version of this script. If the server returns a version larger than
 * this, it is a sign we should reload to upgrade ourselves.
 *
 * @type {Number}
 * @const
 * @private */
var SCRIPT_VERSION = 2015062104;

/**
 * The current backend URL.
 *
 * @type {!string}
 * @private
 */
var backend_url = "/analysis.pl";

/** @type {window.ChessBoard} @private */
var board = null;

/**
 * The most recent analysis data we have from the server
 * (about the most recent position).
 *
 * @type {?Object}
 * @private */
var current_analysis_data = null;

/**
 * If we are displaying previous analysis, this is non-null,
 * and will override most of current_analysis_data.
 *
 * @type {?Object}
 * @private
 */
var displayed_analysis_data = null;

/**
 * Games currently in progress, if any.
 *
 * @type {?Array.<{
 *      name: string,
 *      url: string,
 *      id: string,
 * }>}
 * @private
 */
var current_games = null;

/** @type {Array.<{
 *      from_col: number,
 *      from_row: number,
 *      to_col: number,
 *      to_row: number,
 *      line_width: number,
 *      arrow_size: number,
 *      fg_color: string
 * }>}
 * @private
 */
var arrows = [];

/** @type {Array.<Array.<boolean>>} */
var occupied_by_arrows = [];

var refutation_lines = [];

/** @type {!number} @private */
var move_num = 1;

/** @type {!string} @private */
var toplay = 'W';

/** @type {number} @private */
var ims = 0;

/** @type {boolean} @private */
var sort_refutation_lines_by_score = true;

/** @type {boolean} @private */
var truncate_display_history = true;

/** @type {!string|undefined} @private */
var highlight_from = undefined;

/** @type {!string|undefined} @private */
var highlight_to = undefined;

/** The HTML object of the move currently being highlighted (in red).
 * @type {?jQuery}
 * @private */
var highlighted_move = null;

/** @type {?number} @private */
var unique = null;

/** @type {boolean} @private */
var enable_sound = false;

/**
 * Our best estimate of how many milliseconds we need to add to 
 * new Date() to get the true UTC time. Calibrated against the
 * server clock.
 *
 * @type {?number}
 * @private
 */
var client_clock_offset_ms = null;

var clock_timer = null;

/** The current position on the board, represented as a FEN string.
 * @type {?string}
 * @private
 */
var fen = null;

/** @typedef {{
 *    start_fen: string,
 *    pretty_pv: Array.<string>,
 * }} DisplayLine
 */

/** All PVs that we currently know of.
 *
 * Element 0 is history (or null if no history).
 * Element 1 is current main PV.
 * All remaining elements are refutation lines (multi-PV).
 *
 * @type {Array.<DisplayLine>}
 * @private
 */
var display_lines = [];

/** @type {?DisplayLine} @private */
var current_display_line = null;

/** @type {boolean} @private */
var current_display_line_is_history = false;

/** @type {?number} @private */
var current_display_move = null;

/**
 * The current backend request to get main analysis (not history), if any,
 * so that we can abort it.
 *
 * @type {?jqXHR}
 * @private
 */
var current_analysis_xhr = null;

/**
 * The current timer to fire off a request to get main analysis (not history),
 * if any, so that we can abort it.
 *
 * @type {?Number}
 * @private
 */
var current_analysis_request_timer = null;

/**
 * The current backend request to get historic data, if any.
 *
 * @type {?jqXHR}
 * @private
 */
var current_historic_xhr = null;

var supports_html5_storage = function() {
	try {
		return 'localStorage' in window && window['localStorage'] !== null;
	} catch (e) {
		return false;
	}
}

// Make the unique token persistent so people refreshing the page won't count twice.
// Of course, you can never fully protect against people deliberately wanting to spam.
var get_unique = function() {
	var use_local_storage = supports_html5_storage();
	if (use_local_storage && localStorage['unique']) {
		return localStorage['unique'];
	}
	var unique = Math.random();
	if (use_local_storage) {
		localStorage['unique'] = unique;
	}
	return unique;
}

var request_update = function() {
	current_analysis_request_timer = null;

	current_analysis_xhr = $.ajax({
		url: backend_url + "?ims=" + ims + "&unique=" + unique
	}).done(function(data, textstatus, xhr) {
		sync_server_clock(xhr.getResponseHeader('Date'));
		ims = xhr.getResponseHeader('X-RGLM');
		var num_viewers = xhr.getResponseHeader('X-RGNV');
		var new_data;
		if (Array.isArray(data)) {
			new_data = JSON.parse(JSON.stringify(current_analysis_data));
			JSON_delta.patch(new_data, data);
		} else {
			new_data = data;
		}

		var minimum_version = xhr.getResponseHeader('X-RGMV');
		if (minimum_version && minimum_version > SCRIPT_VERSION) {
			// Upgrade to latest version with a force-reload.
			location.reload(true);
		}

		possibly_play_sound(current_analysis_data, new_data);
		current_analysis_data = new_data;
		update_board();
		update_num_viewers(num_viewers);

		// Next update.
		current_analysis_request_timer = setTimeout(function() { request_update(); }, 100);
	}).fail(function(jqXHR, textStatus, errorThrown) {
		if (textStatus === "abort") {
			// Aborted because we are switching backends. Abandon and don't retry,
			// because another one is already started for us.
		} else {
			// Backend error or similar. Wait ten seconds, then try again.
			current_analysis_request_timer = setTimeout(function() { request_update(); }, 10000);
		}
	});
}

var possibly_play_sound = function(old_data, new_data) {
	if (!enable_sound) {
		return;
	}
	if (old_data === null) {
		return;
	}
	var ding = document.getElementById('ding');
	if (ding && ding.play) {
		if (old_data['position'] && old_data['position']['fen'] &&
		    new_data['position'] && new_data['position']['fen'] &&
		    (old_data['position']['fen'] !== new_data['position']['fen'] ||
		     old_data['position']['move_num'] !== new_data['position']['move_num'])) {
			ding.play();
		}
	}
}

/**
 * @type {!string} server_date_string
 */
var sync_server_clock = function(server_date_string) {
	var server_time_ms = new Date(server_date_string).getTime();
	var client_time_ms = new Date().getTime();
	var estimated_offset_ms = server_time_ms - client_time_ms;

	// In order not to let the noise move us too much back and forth
	// (the server only has one-second resolution anyway), we only
	// change an existing skew if we are at least five seconds off.
	if (client_clock_offset_ms === null ||
	    Math.abs(estimated_offset_ms - client_clock_offset_ms) > 5000) {
		client_clock_offset_ms = estimated_offset_ms;
	}
}

var clear_arrows = function() {
	for (var i = 0; i < arrows.length; ++i) {
		if (arrows[i].svg) {
			if (arrows[i].svg.parentElement) {
				arrows[i].svg.parentElement.removeChild(arrows[i].svg);
			}
			delete arrows[i].svg;
		}
	}
	arrows = [];

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

/** @param {!number} x
 * @return {!number}
 */
var sign = function(x) {
	if (x > 0) {
		return 1;
	} else if (x < 0) {
		return -1;
	} else {
		return 0;
	}
}

/** See if drawing this arrow on the board would cause unduly amount of confusion.
 * @param {!string} from The square the arrow is from (e.g. e4).
 * @param {!string} to The square the arrow is to (e.g. e4).
 * @return {boolean}
 */
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

/** Find a point along the coordinate system given by the given line,
 * <t> units forward from the start of the line, <u> units to the right of it.
 * @param {!number} x1
 * @param {!number} x2
 * @param {!number} y1
 * @param {!number} y2
 * @param {!number} t
 * @param {!number} u
 * @return {!string} The point in "x y" form, suitable for SVG paths.
 */
var point_from_start = function(x1, y1, x2, y2, t, u) {
	var dx = x2 - x1;
	var dy = y2 - y1;

	var norm = 1.0 / Math.sqrt(dx * dx + dy * dy);
	dx *= norm;
	dy *= norm;

	var x = x1 + dx * t + dy * u;
	var y = y1 + dy * t - dx * u;
	return x + " " + y;
}

/** Find a point along the coordinate system given by the given line,
 * <t> units forward from the end of the line, <u> units to the right of it.
 * @param {!number} x1
 * @param {!number} x2
 * @param {!number} y1
 * @param {!number} y2
 * @param {!number} t
 * @param {!number} u
 * @return {!string} The point in "x y" form, suitable for SVG paths.
 */
var point_from_end = function(x1, y1, x2, y2, t, u) {
	var dx = x2 - x1;
	var dy = y2 - y1;

	var norm = 1.0 / Math.sqrt(dx * dx + dy * dy);
	dx *= norm;
	dy *= norm;

	var x = x2 + dx * t + dy * u;
	var y = y2 + dy * t - dx * u;
	return x + " " + y;
}

var position_arrow = function(arrow) {
	if (arrow.svg) {
		if (arrow.svg.parentElement) {
			arrow.svg.parentElement.removeChild(arrow.svg);
		}
		delete arrow.svg;
	}
	if (current_display_line !== null && !current_display_line_is_history) {
		return;
	}

	var pos = $(".square-a8").position();

	var zoom_factor = $("#board").width() / 400.0;
	var line_width = arrow.line_width * zoom_factor;
	var arrow_size = arrow.arrow_size * zoom_factor;

	var square_width = $(".square-a8").width();
	var from_y = (7 - arrow.from_row + 0.5)*square_width;
	var to_y = (7 - arrow.to_row + 0.5)*square_width;
	var from_x = (arrow.from_col + 0.5)*square_width;
	var to_x = (arrow.to_col + 0.5)*square_width;

	var SVG_NS = "http://www.w3.org/2000/svg";
	var XHTML_NS = "http://www.w3.org/1999/xhtml";
	var svg = document.createElementNS(SVG_NS, "svg");
	svg.setAttribute("width", /** @type{number} */ ($("#board").width()));
	svg.setAttribute("height", /** @type{number} */ ($("#board").height()));
	svg.setAttribute("style", "position: absolute");
	svg.setAttribute("position", "absolute");
	svg.setAttribute("version", "1.1");
	svg.setAttribute("class", "c1");
	svg.setAttribute("xmlns", XHTML_NS);

	var x1 = from_x;
	var y1 = from_y;
	var x2 = to_x;
	var y2 = to_y;

	// Draw the line.
	var outline = document.createElementNS(SVG_NS, "path");
	outline.setAttribute("d", "M " + point_from_start(x1, y1, x2, y2, arrow_size / 2, 0) + " L " + point_from_end(x1, y1, x2, y2, -arrow_size / 2, 0));
	outline.setAttribute("xmlns", XHTML_NS);
	outline.setAttribute("stroke", "#666");
	outline.setAttribute("stroke-width", line_width + 2);
	outline.setAttribute("fill", "none");
	svg.appendChild(outline);

	var path = document.createElementNS(SVG_NS, "path");
	path.setAttribute("d", "M " + point_from_start(x1, y1, x2, y2, arrow_size / 2, 0) + " L " + point_from_end(x1, y1, x2, y2, -arrow_size / 2, 0));
	path.setAttribute("xmlns", XHTML_NS);
	path.setAttribute("stroke", arrow.fg_color);
	path.setAttribute("stroke-width", line_width);
	path.setAttribute("fill", "none");
	svg.appendChild(path);

	// Then the arrow head.
	var head = document.createElementNS(SVG_NS, "path");
	head.setAttribute("d",
		"M " +  point_from_end(x1, y1, x2, y2, 0, 0) +
		" L " + point_from_end(x1, y1, x2, y2, -arrow_size, -arrow_size / 2) +
		" L " + point_from_end(x1, y1, x2, y2, -arrow_size * .623, 0.0) +
		" L " + point_from_end(x1, y1, x2, y2, -arrow_size, arrow_size / 2) +
		" L " + point_from_end(x1, y1, x2, y2, 0, 0));
	head.setAttribute("xmlns", XHTML_NS);
	head.setAttribute("stroke", "#000");
	head.setAttribute("stroke-width", "1");
	head.setAttribute("fill", arrow.fg_color);
	svg.appendChild(head);

	$(svg).css({ top: pos.top, left: pos.left });
	document.body.appendChild(svg);
	arrow.svg = svg;
}

/**
 * @param {!string} from_square
 * @param {!string} to_square
 * @param {!string} fg_color
 * @param {number} line_width
 * @param {number} arrow_size
 */
var create_arrow = function(from_square, to_square, fg_color, line_width, arrow_size) {
	var from_col = from_square.charCodeAt(0) - "a1".charCodeAt(0);
	var from_row = from_square.charCodeAt(1) - "a1".charCodeAt(1);
	var to_col   = to_square.charCodeAt(0) - "a1".charCodeAt(0);
	var to_row   = to_square.charCodeAt(1) - "a1".charCodeAt(1);

	// Create arrow.
	var arrow = {
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

var compare_by_sort_key = function(refutation_lines, a, b) {
	var ska = refutation_lines[a]['sort_key'];
	var skb = refutation_lines[b]['sort_key'];
	if (ska < skb) return -1;
	if (ska > skb) return 1;
	return 0;
};

var compare_by_score = function(refutation_lines, a, b) {
	var sa = parseInt(refutation_lines[b]['score_sort_key'], 10);
	var sb = parseInt(refutation_lines[a]['score_sort_key'], 10);
	return sa - sb;
}

/**
 * Fake multi-PV using the refutation lines. Find all “relevant” moves,
 * sorted by quality, descending.
 *
 * @param {!Object} data
 * @param {number} margin The maximum number of centipawns worse than the
 *     best move can be and still be included.
 * @return {Array.<string>} The UCI representation (e.g. e1g1) of all
 *     moves, in score order.
 */
var find_nonstupid_moves = function(data, margin) {
	// First of all, if there are any moves that are more than 0.5 ahead of
	// the primary move, the refutation lines are probably bunk, so just
	// kill them all. 
	var best_score = undefined;
	var pv_score = undefined;
	for (var move in data['refutation_lines']) {
		var score = parseInt(data['refutation_lines'][move]['score_sort_key'], 10);
		if (move == data['pv_uci'][0]) {
			pv_score = score;
		}
		if (best_score === undefined || score > best_score) {
			best_score = score;
		}
		if (!(data['refutation_lines'][move]['depth'] >= 8)) {
			return [];
		}
	}

	if (best_score - pv_score > 50) {
		return [];
	}

	// Now find all moves that are within “margin” of the best score.
	// The PV move will always be first.
	var moves = [];
	for (var move in data['refutation_lines']) {
		var score = parseInt(data['refutation_lines'][move]['score_sort_key'], 10);
		if (move != data['pv_uci'][0] && best_score - score <= margin) {
			moves.push(move);
		}
	}
	moves = moves.sort(function(a, b) { return compare_by_score(data['refutation_lines'], a, b) });
	moves.unshift(data['pv_uci'][0]);

	return moves;
}

/**
 * @param {number} x
 * @return {!string}
 */
var thousands = function(x) {
	return String(x).split('').reverse().join('').replace(/(\d{3}\B)/g, '$1,').split('').reverse().join('');
}

/**
 * @param {!string} fen
 * @param {Array.<string>} pretty_pv
 * @param {number} move_num
 * @param {!string} toplay
 * @param {number=} opt_limit
 * @param {boolean=} opt_showlast
 */
var add_pv = function(fen, pretty_pv, move_num, toplay, opt_limit, opt_showlast) {
	display_lines.push({
		start_fen: fen,
		pretty_pv: pretty_pv,
	});
	return print_pv(display_lines.length - 1, pretty_pv, move_num, toplay, opt_limit, opt_showlast);
}

/**
 * @param {number} line_num
 * @param {Array.<string>} pretty_pv
 * @param {number} move_num
 * @param {!string} toplay
 * @param {number=} opt_limit
 * @param {boolean=} opt_showlast
 */
var print_pv = function(line_num, pretty_pv, move_num, toplay, opt_limit, opt_showlast) {
	var pv = '';
	var i = 0;
	if (opt_limit && opt_showlast && pretty_pv.length > opt_limit) {
		// Truncate the PV at the beginning (instead of at the end).
		// We assume here that toplay is 'W'. We also assume that if
		// opt_showlast is set, then it is the history, and thus,
		// the UI should be to expand the history.
		pv = '(<a class="move" href="javascript:collapse_history(false)">…</a>) ';
		i = pretty_pv.length - opt_limit;
		if (i % 2 == 1) {
			++i;
		}
		move_num += i / 2;
	} else if (toplay == 'B' && pretty_pv.length > 0) {
		var move = "<a class=\"move\" id=\"automove" + line_num + "-0\" href=\"javascript:show_line(" + line_num + ", " + 0 + ");\">" + pretty_pv[0] + "</a>";
		pv = move_num + '. … ' + move;
		toplay = 'W';
		++i;
		++move_num;
	}
	for ( ; i < pretty_pv.length; ++i) {
		var move = "<a class=\"move\" id=\"automove" + line_num + "-" + i + "\" href=\"javascript:show_line(" + line_num + ", " + i + ");\">" + pretty_pv[i] + "</a>";

		if (toplay == 'W') {
			if (i > opt_limit && !opt_showlast) {
				return pv + ' (…)';
			}
			if (pv != '') {
				pv += ' ';
			}
			pv += move_num + '. ' + move;
			++move_num;
			toplay = 'B';
		} else {
			pv += ' ' + move;
			toplay = 'W';
		}
	}
	return pv;
}

/** Update the highlighted to/from squares on the board.
 * Based on the global "highlight_from" and "highlight_to" variables.
 */
var update_board_highlight = function() {
	$("#board").find('.square-55d63').removeClass('nonuglyhighlight');
	if ((current_display_line === null || current_display_line_is_history) &&
	    highlight_from !== undefined && highlight_to !== undefined) {
		$("#board").find('.square-' + highlight_from).addClass('nonuglyhighlight');
		$("#board").find('.square-' + highlight_to).addClass('nonuglyhighlight');
	}
}

var update_history = function() {
	if (display_lines[0] === null || display_lines[0].pretty_pv.length == 0) {
		$("#history").html("No history");
	} else if (truncate_display_history) {
		$("#history").html(print_pv(0, display_lines[0].pretty_pv, 1, 'W', 8, true));
	} else {
		$("#history").html(
			'(<a class="move" href="javascript:collapse_history(true)">collapse</a>) ' +
			print_pv(0, display_lines[0].pretty_pv, 1, 'W'));
	}
}

/**
 * @param {!boolean} truncate_history
 */
var collapse_history = function(truncate_history) {
	truncate_display_history = truncate_history;
	update_history();
}
window['collapse_history'] = collapse_history;

/** Update the HTML display of multi-PV from the global "refutation_lines".
 *
 * Also recreates the global "display_lines".
 */
var update_refutation_lines = function() {
	if (fen === null) {
		return;
	}
	if (display_lines.length > 2) {
		// Truncate so that only the history and PV is left.
		display_lines = [ display_lines[0], display_lines[1] ];
	}

	var tbl = $("#refutationlines");
	tbl.empty();

	var moves = [];
	for (var move in refutation_lines) {
		moves.push(move);
	}
	var compare = sort_refutation_lines_by_score ? compare_by_score : compare_by_sort_key;
	moves = moves.sort(function(a, b) { return compare(refutation_lines, a, b) });
	for (var i = 0; i < moves.length; ++i) {
		var line = refutation_lines[moves[i]];

		var tr = document.createElement("tr");

		var move_td = document.createElement("td");
		tr.appendChild(move_td);
		$(move_td).addClass("move");
		if (line['pv_pretty'].length == 0) {
			$(move_td).text(line['pretty_move']);
		} else {
			var move = "<a class=\"move\" href=\"javascript:show_line(" + display_lines.length + ", " + 0 + ");\">" + line['pretty_move'] + "</a>";
			$(move_td).html(move);
		}

		var score_td = document.createElement("td");
		tr.appendChild(score_td);
		$(score_td).addClass("score");
		$(score_td).text(line['pretty_score']);

		var depth_td = document.createElement("td");
		tr.appendChild(depth_td);
		$(depth_td).addClass("depth");
		$(depth_td).text("d" + line['depth']);

		var pv_td = document.createElement("td");
		tr.appendChild(pv_td);
		$(pv_td).addClass("pv");
		$(pv_td).html(add_pv(fen, line['pv_pretty'], move_num, toplay, 10));

		tbl.append(tr);
	}

	// Make one of the links clickable and the other nonclickable.
	if (sort_refutation_lines_by_score) {
		$("#sortbyscore0").html("<a href=\"javascript:resort_refutation_lines(false)\">Move</a>");
		$("#sortbyscore1").html("<strong>Score</strong>");
	} else {
		$("#sortbyscore0").html("<strong>Move</strong>");
		$("#sortbyscore1").html("<a href=\"javascript:resort_refutation_lines(true)\">Score</a>");
	}

	// Update the move highlight, as we've rewritten all the HTML.
	update_move_highlight();
}

/**
 * Create a Chess.js board object, containing the given position plus the given moves,
 * up to the given limit.
 *
 * @param {?string} fen
 * @param {Array.<string>} moves
 * @param {number} last_move
 */
var chess_from = function(fen, moves, last_move) {
	var hiddenboard = new Chess();
	if (fen !== null) {
		hiddenboard.load(fen);
	}
	for (var i = 0; i <= last_move; ++i) {
		if (moves[i] === '0-0') {
			hiddenboard.move('O-O');
		} else if (moves[i] === '0-0-0') {
			hiddenboard.move('O-O-O');
		} else {
			hiddenboard.move(moves[i]);
		}
	}
	return hiddenboard;
}

var update_game_list = function(games) {
	$("#games").text("");
	if (games === null) {
		return;
	}

	var games_div = document.getElementById('games');
	for (var game_num = 0; game_num < games.length; ++game_num) {
		var game = games[game_num];
		var game_span = document.createElement("span");
		game_span.setAttribute("class", "game");

		var game_name = document.createTextNode(game['name']);
		if (game['url'] === backend_url) {
			game_span.appendChild(game_name);
		} else {
			var game_a = document.createElement("a");
			game_a.setAttribute("href", "#" + game['id']);
			game_a.appendChild(game_name);
			game_span.appendChild(game_a);
		}
		games_div.appendChild(game_span);
	}
}

/**
 * Try to find a running game that matches with the current hash,
 * and switch to it if we're not already displaying it.
 */
var possibly_switch_game_from_hash = function() {
	if (current_games === null) {
		return;
	}

	var hash = window.location.hash.replace(/^#/,'');
	for (var i = 0; i < current_games.length; ++i) {
		if (current_games[i]['id'] === hash) {
			if (backend_url !== current_games[i]['url']) {
				switch_backend(current_games[i]['url']);
			}
			return;
		}
	}
}

/** Update all the HTML on the page, based on current global state.
 */
var update_board = function() {
	var data = displayed_analysis_data || current_analysis_data;
	var current_data = current_analysis_data;  // Convenience alias.

	display_lines = [];

	// Print the history. This is pretty much the only thing that's
	// unconditionally taken from current_data (we're not interested in
	// historic history).
	if (current_data['position']['pretty_history']) {
		add_pv('start', current_data['position']['pretty_history'], 1, 'W', 8, true);
	} else {
		display_lines.push(null);
	}
	update_history();

	// Games currently in progress, if any.
	if (current_data['games']) {
		current_games = current_data['games'];
		possibly_switch_game_from_hash();
		update_game_list(current_data['games']);
	} else {
		current_games = null;
		update_game_list(null);
	}

	// The headline. Names are always fetched from current_data;
	// the rest can depend a bit.
	var headline;
	if (current_data &&
	    current_data['position']['player_w'] && current_data['position']['player_b']) {
		headline = current_data['position']['player_w'] + '–' +
			current_data['position']['player_b'] + ', analysis';
	} else {
		headline = 'Analysis';
	}

	// Credits, where applicable. Note that we don't want the footer to change a lot
	// when e.g. viewing history, so if any of these changed during the game,
	// use the current one still.
	if (current_data['using_lomonosov']) {
		$("#lomonosov").show();
	} else {
		$("#lomonosov").hide();
	}

	// Credits: The engine name/version.
	if (current_data['engine'] && current_data['engine']['name'] !== null) {
		$("#engineid").text(current_data['engine']['name']);
	}

	// Credits: The engine URL.
	if (current_data['engine'] && current_data['engine']['url']) {
		$("#engineid").attr("href", current_data['engine']['url']);
	} else {
		$("#engineid").removeAttr("href");
	}

	// Credits: Engine details.
	if (current_data['engine'] && current_data['engine']['details']) {
		$("#enginedetails").text(" (" + current_data['engine']['details'] + ")");
	} else {
		$("#enginedetails").text("");
	}

	// Credits: Move source, possibly with URL.
	if (current_data['move_source'] && current_data['move_source_url']) {
		$("#movesource").text("Moves provided by ");
		var movesource_a = document.createElement("a");
		movesource_a.setAttribute("href", current_data['move_source_url']);
		var movesource_text = document.createTextNode(current_data['move_source']);
		movesource_a.appendChild(movesource_text);
		var movesource_period = document.createTextNode(".");
		document.getElementById("movesource").appendChild(movesource_a);
		document.getElementById("movesource").appendChild(movesource_period);
	} else if (current_data['move_source']) {
		$("#movesource").text("Moves provided by " + current_data['move_source'] + ".");
	} else {
		$("#movesource").text("");
	}

	var last_move;
	if (displayed_analysis_data) {
		// Displaying some non-current position, pick out the last move
		// from the history. This will work even if the fetch failed.
		last_move = format_halfmove_with_number(
			current_display_line.pretty_pv[current_display_move],
			current_display_move + 1);
		headline += ' after ' + last_move;
	} else if (data['position']['last_move'] !== 'none') {
		last_move = format_move_with_number(
			data['position']['last_move'],
			data['position']['move_num'],
			data['position']['toplay'] == 'W');
		headline += ' after ' + last_move;
	} else {
		last_move = null;
	}
	$("#headline").text(headline);

	// The <title> contains a very brief headline.
	var title_elems = [];
	if (data['short_score'] !== undefined && data['short_score'] !== null) {
		title_elems.push(data['short_score'].replace(/^ /, ""));
	}
	if (last_move !== null) {
		title_elems.push(last_move);
	}

	if (title_elems.length != 0) {
		document.title = '(' + title_elems.join(', ') + ') analysis.sesse.net';
	} else {
		document.title = 'analysis.sesse.net';
	}

	// The last move (shown by highlighting the from and to squares).
	if (data['position'] && data['position']['last_move_uci']) {
		highlight_from = data['position']['last_move_uci'].substr(0, 2);
		highlight_to = data['position']['last_move_uci'].substr(2, 2);
	} else if (current_display_line_is_history && current_display_move >= 0) {
		// We don't have historic analysis for this position, but we
		// can reconstruct what the last move was by just replaying
		// from the start.
		var hiddenboard = chess_from(null, current_display_line.pretty_pv, current_display_move);
		var moves = hiddenboard.history({ verbose: true });
		var last_move = moves.pop();
		highlight_from = last_move.from;
		highlight_to = last_move.to;
	} else {
		highlight_from = highlight_to = undefined;
	}
	update_board_highlight();

	if (data['failed']) {
		$("#score").text("No analysis for this move");
		$("#pvtitle").text("PV:");
		$("#pv").empty();
		$("#searchstats").html("&nbsp;");
		$("#refutationlines").empty();
		$("#whiteclock").empty();
		$("#blackclock").empty();
		refutation_lines = [];
		update_refutation_lines();
		clear_arrows();
		update_displayed_line();
		update_move_highlight();
		return;
	}

	update_clock();

	// The score.
	if (data['score'] !== null) {
		$("#score").text(data['score']);
	}

	// The search stats.
	if (data['tablebase'] == 1) {
		$("#searchstats").text("Tablebase result");
	} else if (data['nodes'] && data['nps'] && data['depth']) {
		var stats = thousands(data['nodes']) + ' nodes, ' + thousands(data['nps']) + ' nodes/sec, depth ' + data['depth'] + ' ply';
		if (data['seldepth']) {
			stats += ' (' + data['seldepth'] + ' selective)';
		}
		if (data['tbhits'] && data['tbhits'] > 0) {
			if (data['tbhits'] == 1) {
				stats += ', one Syzygy hit';
			} else {
				stats += ', ' + thousands(data['tbhits']) + ' Syzygy hits';
			}
		}

		$("#searchstats").text(stats);
	} else {
		$("#searchstats").text("");
	}

	// Update the board itself.
	fen = data['position']['fen'];
	update_displayed_line();

	// Print the PV.
	$("#pvtitle").text("PV:");
	$("#pv").html(add_pv(data['position']['fen'], data['pv_pretty'], data['position']['move_num'], data['position']['toplay']));

	// Update the PV arrow.
	clear_arrows();
	if (data['pv_uci'].length >= 1) {
		// draw a continuation arrow as long as it's the same piece
		for (var i = 0; i < data['pv_uci'].length; i += 2) {
			var from = data['pv_uci'][i].substr(0, 2);
			var to = data['pv_uci'][i].substr(2,4);
			if ((i >= 2 && from != data['pv_uci'][i - 2].substr(2, 2)) ||
			     interfering_arrow(from, to)) {
				break;
			}
			create_arrow(from, to, '#f66', 6, 20);
		}

		var alt_moves = find_nonstupid_moves(data, 30);
		for (var i = 1; i < alt_moves.length && i < 3; ++i) {
			create_arrow(alt_moves[i].substr(0, 2),
				     alt_moves[i].substr(2, 2), '#f66', 1, 10);
		}
	}

	// See if all semi-reasonable moves have only one possible response.
	if (data['pv_uci'].length >= 2) {
		var nonstupid_moves = find_nonstupid_moves(data, 300);
		var response = data['pv_uci'][1];
		for (var i = 0; i < nonstupid_moves.length; ++i) {
			if (nonstupid_moves[i] == data['pv_uci'][0]) {
				// ignore the PV move for refutation lines.
				continue;
			}
			if (!data['refutation_lines'] ||
			    !data['refutation_lines'][nonstupid_moves[i]] ||
			    !data['refutation_lines'][nonstupid_moves[i]]['pv_uci'] ||
			    data['refutation_lines'][nonstupid_moves[i]]['pv_uci'].length < 1) {
				// Incomplete PV, abort.
				response = undefined;
				break;
			}
			var this_response = data['refutation_lines'][nonstupid_moves[i]]['pv_uci'][1];
			if (response !== this_response) {
				// Different response depending on lines, abort.
				response = undefined;
				break;
			}
		}

		if (nonstupid_moves.length > 0 && response !== undefined) {
			create_arrow(response.substr(0, 2),
				     response.substr(2, 2), '#66f', 6, 20);
		}
	}

	// Update the refutation lines.
	fen = data['position']['fen'];
	move_num = data['position']['move_num'];
	toplay = data['position']['toplay'];
	refutation_lines = data['refutation_lines'];
	update_refutation_lines();

	// Update the sparkline last, since its size depends on how everything else reflowed.
	update_sparkline(data);
}

var update_sparkline = function(data) {
	if (data && data['score_history']) {
		var first_move_num = undefined;
		for (var halfmove_num in data['score_history']) {
			halfmove_num = parseInt(halfmove_num);
			if (first_move_num === undefined || halfmove_num < first_move_num) {
				first_move_num = halfmove_num;
			}
		}
		if (first_move_num !== undefined) {
			var last_move_num = data['position']['move_num'] * 2 - 3;
			if (data['position']['toplay'] === 'B') {
				++last_move_num;
			}

			// Possibly truncate some moves if we don't have enough width.
			// FIXME: Sometimes width() for #scorecontainer (and by extent,
			// #scoresparkcontainer) on Chrome for mobile seems to start off
			// at something very small, and then suddenly snap back into place.
			// Figure out why.
			var max_moves = Math.floor($("#scoresparkcontainer").width() / 5) - 5;
			if (last_move_num - first_move_num > max_moves) {
				first_move_num = last_move_num - max_moves;
			}

			var min_score = -100;
			var max_score = 100;
			var last_score = null;
			var scores = [];
			for (var halfmove_num = first_move_num; halfmove_num <= last_move_num; ++halfmove_num) {
				if (data['score_history'][halfmove_num]) {
					var score = data['score_history'][halfmove_num][0];
					if (score < min_score) min_score = score;
					if (score > max_score) max_score = score;
					last_score = data['score_history'][halfmove_num][0];
				}
				scores.push(last_score);
			}
			if (data['plot_score']) {
				scores.push(data['plot_score']);
			}
			// FIXME: at some widths, calling sparkline() seems to push
			// #scorecontainer under the board.
			$("#scorespark").sparkline(scores, {
				type: 'bar',
				zeroColor: 'gray',
				chartRangeMin: min_score,
				chartRangeMax: max_score,
				tooltipFormatter: function(sparkline, options, fields) {
					return format_tooltip(data, fields[0].offset + first_move_num);
				}
			});
		} else {
			$("#scorespark").text("");
		}
	} else {
		$("#scorespark").text("");
	}
}

/**
 * @param {number} num_viewers
 */
var update_num_viewers = function(num_viewers) {
	if (num_viewers === null) {
		$("#numviewers").text("");
	} else if (num_viewers == 1) {
		$("#numviewers").text("You are the only current viewer");
	} else {
		$("#numviewers").text(num_viewers + " current viewers");
	}
}

var update_clock = function() {
	clearTimeout(clock_timer);

	var data = displayed_analysis_data || current_analysis_data;
	if (data['position']) {
		var result = data['position']['result'];
		if (result === '1-0') {
			$("#whiteclock").text("1");
			$("#blackclock").text("0");
			$("#whiteclock").removeClass("running-clock");
			$("#blackclock").removeClass("running-clock");
			return;
		}
		if (result === '1/2-1/2') {
			$("#whiteclock").text("1/2");
			$("#blackclock").text("1/2");
			$("#whiteclock").removeClass("running-clock");
			$("#blackclock").removeClass("running-clock");
			return;
		}	
		if (result === '0-1') {
			$("#whiteclock").text("0");
			$("#blackclock").text("1");
			$("#whiteclock").removeClass("running-clock");
			$("#blackclock").removeClass("running-clock");
			return;
		}
	}

	var white_clock_ms = null;
	var black_clock_ms = null;
	var show_seconds = false;

	// Static clocks.
	if (data['position'] &&
	    data['position']['white_clock'] &&
	    data['position']['black_clock']) {
		white_clock_ms = data['position']['white_clock'] * 1000;
		black_clock_ms = data['position']['black_clock'] * 1000;
	}

	// Dynamic clock (only one, obviously).
	var color;
	if (data['position']['white_clock_target']) {
		color = "white";
		$("#whiteclock").addClass("running-clock");
		$("#blackclock").removeClass("running-clock");
	} else if (data['position']['black_clock_target']) {
		color = "black";
		$("#whiteclock").removeClass("running-clock");
		$("#blackclock").addClass("running-clock");
	} else {
		$("#whiteclock").removeClass("running-clock");
		$("#blackclock").removeClass("running-clock");
	}
	var remaining_ms;
	if (color) {
		var now = new Date().getTime() + client_clock_offset_ms;
		remaining_ms = data['position'][color + '_clock_target'] * 1000 - now;
		if (color === "white") {
			white_clock_ms = remaining_ms;
		} else {
			black_clock_ms = remaining_ms;
		}
	}

	if (white_clock_ms === null || black_clock_ms === null) {
		$("#whiteclock").empty();
		$("#blackclock").empty();
		return;
	}

	// If either player has ten minutes or less left, add the second counters.
	var show_seconds = (white_clock_ms < 60 * 10 * 1000 || black_clock_ms < 60 * 10 * 1000);

	if (color) {
		// See when the clock will change next, and update right after that.
		var next_update_ms;
		if (show_seconds) {
			next_update_ms = remaining_ms % 1000 + 100;
		} else {
			next_update_ms = remaining_ms % 60000 + 100;
		}
		clock_timer = setTimeout(update_clock, next_update_ms);
	}

	$("#whiteclock").text(format_clock(white_clock_ms, show_seconds));
	$("#blackclock").text(format_clock(black_clock_ms, show_seconds));
}

/**
 * @param {Number} remaining_ms
 * @param {boolean} show_seconds
 */
var format_clock = function(remaining_ms, show_seconds) {
	if (remaining_ms <= 0) {
		if (show_seconds) {
			return "00:00:00";
		} else {
			return "00:00";
		}
	}

	var remaining = Math.floor(remaining_ms / 1000);
	var seconds = remaining % 60;
	remaining = (remaining - seconds) / 60;
	var minutes = remaining % 60;
	remaining = (remaining - minutes) / 60;
	var hours = remaining;
	if (show_seconds) {
		return format_2d(hours) + ":" + format_2d(minutes) + ":" + format_2d(seconds);
	} else {
		return format_2d(hours) + ":" + format_2d(minutes);
	}
}

/**
 * @param {Number} x
 */
var format_2d = function(x) {
	if (x >= 10) {
		return x;
	} else {
		return "0" + x;
	}
}

/**
 * @param {string} move
 * @param {Number} move_num
 * @param {boolean} white_to_play
 */
var format_move_with_number = function(move, move_num, white_to_play) {
	var ret;
	if (white_to_play) {
		ret = (move_num - 1) + '… ';
	} else {
		ret = move_num + '. ';
	}
	ret += move;
	return ret;
}

/**
 * @param {string} move
 * @param {Number} halfmove_num
 */
var format_halfmove_with_number = function(move, halfmove_num) {
	return format_move_with_number(
		move,
		Math.floor(halfmove_num / 2) + 1,
		halfmove_num % 2 == 0);
}

/**
 * @param {Object} data
 * @param {Number} halfmove_num
 */
var format_tooltip = function(data, halfmove_num) {
	if (data['score_history'][halfmove_num] ||
	    halfmove_num === data['position']['pretty_history'].length) {
		var move;
		var short_score;
		if (halfmove_num === data['position']['pretty_history'].length) {
			move = data['position']['last_move'];
			short_score = data['short_score'];
		} else {
			move = data['position']['pretty_history'][halfmove_num];
			short_score = data['score_history'][halfmove_num][1];
		}
		var move_with_number = format_halfmove_with_number(move, halfmove_num);

		return "After " + move_with_number + ": " + short_score;
	} else {
		for (var i = halfmove_num; i --> 0; ) {
			if (data['score_history'][i]) {
				var move = data['position']['pretty_history'][i];
				return "[Analysis kept from " + format_halfmove_with_number(move, i) + "]";
			}
		}
	}
}

/**
 * @param {boolean} sort_by_score
 */
var resort_refutation_lines = function(sort_by_score) {
	sort_refutation_lines_by_score = sort_by_score;
	if (supports_html5_storage()) {
		localStorage['sort_refutation_lines_by_score'] = sort_by_score ? 1 : 0;
	}
	update_refutation_lines();
}
window['resort_refutation_lines'] = resort_refutation_lines;

/**
 * @param {boolean} truncate_history
 */
var set_truncate_history = function(truncate_history) {
	truncate_display_history = truncate_history;
	update_refutation_lines();
}
window['set_truncate_history'] = set_truncate_history;

/**
 * @param {number} line_num
 * @param {number} move_num
 */
var show_line = function(line_num, move_num) {
	if (line_num == -1) {
		current_display_line = null;
		current_display_move = null;
		if (displayed_analysis_data) {
			// TODO: Support exiting to history position if we are in an
			// analysis line of a history position.
			displayed_analysis_data = null;
			update_board();
		}
	} else {
		current_display_line = jQuery.extend({}, display_lines[line_num]);  // Shallow clone.
		current_display_move = move_num;
	}
	current_display_line_is_history = (line_num == 0);

	update_historic_analysis();
	update_displayed_line();
	update_board_highlight();
	update_move_highlight();
	redraw_arrows();
}
window['show_line'] = show_line;

var prev_move = function() {
	if (current_display_move > -1) {
		--current_display_move;
	}
	update_historic_analysis();
	update_displayed_line();
	update_move_highlight();
}
window['prev_move'] = prev_move;

var next_move = function() {
	if (current_display_line && current_display_move < current_display_line.pretty_pv.length - 1) {
		++current_display_move;
	}
	update_historic_analysis();
	update_displayed_line();
	update_move_highlight();
}
window['next_move'] = next_move;

var update_historic_analysis = function() {
	if (!current_display_line_is_history) {
		return;
	}
	if (current_display_move == current_display_line.pretty_pv.length - 1) {
		displayed_analysis_data = null;
		update_board();
	}

	// Fetch old analysis for this line if it exists.
	var hiddenboard = chess_from(null, current_display_line.pretty_pv, current_display_move);
	var filename = "/history/move" + (current_display_move + 1) + "-" +
		hiddenboard.fen().replace(/ /g, '_').replace(/\//g, '-') + ".json";

	current_historic_xhr = $.ajax({
		url: filename
	}).done(function(data, textstatus, xhr) {
		displayed_analysis_data = data;
		update_board();
	}).fail(function(jqXHR, textStatus, errorThrown) {
		if (textStatus === "abort") {
			// Aborted because we are switching backends. Don't do anything;
			// we will already have been cleared.
		} else {
			displayed_analysis_data = {'failed': true};
			update_board();
		}
	});
}

/**
 * @param {string} fen
 */
var update_imbalance = function(fen) {
	var hiddenboard = new Chess(fen);
	var imbalance = {'k': 0, 'q': 0, 'r': 0, 'b': 0, 'n': 0, 'p': 0};
	for (var row = 0; row < 8; ++row) {
		for (var col = 0; col < 8; ++col) {
			var col_text = String.fromCharCode('a1'.charCodeAt(0) + col);
			var row_text = String.fromCharCode('a1'.charCodeAt(1) + row);
			var square = col_text + row_text;
			var contents = hiddenboard.get(square);
			if (contents !== null) {
				if (contents.color === 'w') {
					++imbalance[contents.type];
				} else {
					--imbalance[contents.type];
				}
			}
		}
	}
	var white_imbalance = '';
	var black_imbalance = '';
	for (var piece in imbalance) {
		for (var i = 0; i < imbalance[piece]; ++i) {
			white_imbalance += '<img src="img/chesspieces/wikipedia/w' + piece.toUpperCase() + '.png" alt="" style="width: 15px;height: 15px;">';
		}
		for (var i = 0; i < -imbalance[piece]; ++i) {
			black_imbalance += '<img src="img/chesspieces/wikipedia/b' + piece.toUpperCase() + '.png" alt="" style="width: 15px;height: 15px;">';
		}
	}
	$('#whiteimbalance').html(white_imbalance);
	$('#blackimbalance').html(black_imbalance);
}

/** Mark the currently selected move in red.
 */
var update_move_highlight = function() {
	if (highlighted_move !== null) {
		highlighted_move.removeClass('highlight'); 
	}
	if (current_display_line) {
		// See if the current displayed line is identical to any of the ones
		// we have on screen. (It might not be if e.g. the analysis reloaded
		// since we started looking.)
		for (var i = 0; i < display_lines.length; ++i) {
			var line = display_lines[i];
			if (current_display_line.start_fen !== line.start_fen) continue;
			if (current_display_line.pretty_pv.length !== line.pretty_pv.length) continue;
			var ok = true;
			for (var j = 0; j < line.pretty_pv.length; ++j) {
				if (current_display_line.pretty_pv[j] !== line.pretty_pv[j]) {
					ok = false;
					break;
				}
			}
			if (ok) {
				highlighted_move = $("#automove" + i + "-" + current_display_move);
				highlighted_move.addClass('highlight');
				break;
			}
		}
	}
}

var update_displayed_line = function() {
	if (current_display_line === null) {
		$("#linenav").hide();
		$("#linemsg").show();
		board.position(fen);
		update_imbalance(fen);
		return;
	}

	$("#linenav").show();
	$("#linemsg").hide();

	if (current_display_move <= 0) {
		$("#prevmove").html("Previous");
	} else {
		$("#prevmove").html("<a href=\"javascript:prev_move();\">Previous</a></span>");
	}
	if (current_display_move == current_display_line.pretty_pv.length - 1) {
		$("#nextmove").html("Next");
	} else {
		$("#nextmove").html("<a href=\"javascript:next_move();\">Next</a></span>");
	}

	var hiddenboard = chess_from(current_display_line.start_fen, current_display_line.pretty_pv, current_display_move);
	board.position(hiddenboard.fen());
	update_imbalance(hiddenboard.fen());
}

/**
 * @param {boolean} param_enable_sound
 */
var set_sound = function(param_enable_sound) {
	enable_sound = param_enable_sound;
	if (enable_sound) {
		$("#soundon").html("<strong>On</strong>");
		$("#soundoff").html("<a href=\"javascript:set_sound(false)\">Off</a>");

		// Seemingly at least Firefox prefers MP3 over Opus; tell it otherwise,
		// and also preload the file since the user has selected audio.
		var ding = document.getElementById('ding');
		if (ding && ding.canPlayType && ding.canPlayType('audio/ogg; codecs="opus"') === 'probably') {
			ding.src = 'ding.opus';
			ding.load();
		}
	} else {
		$("#soundon").html("<a href=\"javascript:set_sound(true)\">On</a>");
		$("#soundoff").html("<strong>Off</strong>");
	}
	if (supports_html5_storage()) {
		localStorage['enable_sound'] = enable_sound ? 1 : 0;
	}
}
window['set_sound'] = set_sound;

/**
 * @param {string} new_backend_url
 */
var switch_backend = function(new_backend_url) {
	// Stop looking at historic data.
	current_display_line = null;
	current_display_move = null;
	displayed_analysis_data = null;
	if (current_historic_xhr) {
		current_historic_xhr.abort();
	}

	// If we already have a backend response going, abort it.
	if (current_analysis_xhr) {
		current_analysis_xhr.abort();
	}

	// Otherwise, we should have a timer going to start a new one.
	// Kill that, too.
	if (current_analysis_request_timer) {
		clearTimeout(current_analysis_request_timer);
		current_analysis_request_timer = null;
	}

	// Request an immediate fetch with the new backend.
	backend_url = new_backend_url;
	current_analysis_data = null;
	ims = 0;
	request_update();
}
window['switch_backend'] = switch_backend;

var init = function() {
	unique = get_unique();

	// Load settings from HTML5 local storage if available.
	if (supports_html5_storage() && localStorage['enable_sound']) {
		set_sound(parseInt(localStorage['enable_sound']));
	} else {
		set_sound(false);
	}
	if (supports_html5_storage() && localStorage['sort_refutation_lines_by_score']) {
		sort_refutation_lines_by_score = parseInt(localStorage['sort_refutation_lines_by_score']);
	} else {
		sort_refutation_lines_by_score = true;
	}

	// Create board.
	board = new window.ChessBoard('board', 'start');

	request_update();
	$(window).resize(function() {
		board.resize();
		update_sparkline(displayed_analysis_data || current_analysis_data);
		update_board_highlight();
		redraw_arrows();
	});
	$(window).keyup(function(event) {
		if (event.which == 39) {
			next_move();
		} else if (event.which == 37) {
			prev_move();
		}
	});
	window.addEventListener('hashchange', possibly_switch_game_from_hash, false);
};
$(document).ready(init);

})();
