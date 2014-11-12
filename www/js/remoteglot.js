(function() {

/** @type {window.ChessBoard} @private */
var board = null;

/** @type {window.ChessBoard} @private */
var hiddenboard = null;

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

/** @type {?jQuery} @private */
var highlighted_move = null;

/** @type {?number} @private */
var unique = null;

/** The current position on the board, represented as a FEN string.
 * @type {?string}
 * @private
 */
var fen = null;

/** @typedef {{
 *    start_fen: string,
 *    uci_pv: Array.<string>,
 *    pretty_pv: Array.<string>,
 *    line_num: number
 * }} DisplayLine
 */

/** @type {Array.<DisplayLine>}
 * @private
 */
var display_lines = [];

/** @type {?DisplayLine} @private */
var current_display_line = null;

/** @type {?number} @private */
var current_display_move = null;

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
	$.ajax({
		url: "http://analysis.sesse.net/analysis.pl?ims=" + ims + "&unique=" + unique
		//url: "http://analysis.sesse.net:5000/analysis.pl?ims=" + ims + "&unique=" + unique
	}).done(function(data, textstatus, xhr) {
		ims = xhr.getResponseHeader('X-Remoteglot-Last-Modified');
		var num_viewers = xhr.getResponseHeader('X-Remoteglot-Num-Viewers');
		update_board(data, num_viewers);
	}).fail(function() {
		// Wait ten seconds, then try again.
		setTimeout(function() { request_update(); }, 10000);
	});
}

var clear_arrows = function() {
	for (var i = 0; i < arrows.length; ++i) {
		if (arrows[i].svg) {
			arrows[i].svg.parentElement.removeChild(arrows[i].svg);
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
		arrow.svg.parentElement.removeChild(arrow.svg);
		delete arrow.svg;
	}
	if (current_display_line !== null) {
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
 * @param {Array.<string>} uci_pv
 * @param {Array.<string>} pretty_pv
 * @param {number} move_num
 * @param {!string} toplay
 * @param {number=} opt_limit
 * @param {boolean=} opt_showlast
 */
var add_pv = function(fen, uci_pv, pretty_pv, move_num, toplay, opt_limit, opt_showlast) {
	display_lines.push({
		start_fen: fen,
		uci_pv: uci_pv,
		pretty_pv: pretty_pv,
		line_number: display_lines.length
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
	} else if (toplay == 'B') {
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

var update_highlight = function() {
	$("#board").find('.square-55d63').removeClass('nonuglyhighlight');
	if (current_display_line === null && highlight_from !== undefined && highlight_to !== undefined) {
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

var update_refutation_lines = function() {
	if (fen === null) {
		return;
	}
	if (display_lines.length > 2) {
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
		if (line['pv_uci'].length == 0) {
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
		$(pv_td).html(add_pv(fen, line['pv_uci'], line['pv_pretty'], move_num, toplay, 10));

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
}

/**
 * @param {Object} data
 * @param {number} num_viewers
 */
var update_board = function(data, num_viewers) {
	display_lines = [];

	// The headline.
	var headline;
	if (data['position']['player_w'] && data['position']['player_b']) {
		headline = data['position']['player_w'] + '–' +
			data['position']['player_b'] + ', analysis';
	} else {
		headline = 'Analysis';
	}
	if (data['position']['last_move'] !== 'none') {
		headline += ' after '
		if (data['position']['toplay'] == 'W') {
			headline += (data['position']['move_num']-1) + '… ';
		} else {
			headline += data['position']['move_num'] + '. ';
		}
		headline += data['position']['last_move'];
	}

	$("#headline").text(headline);

	if (num_viewers === null) {
		$("#numviewers").text("");
	} else if (num_viewers == 1) {
		$("#numviewers").text("You are the only current viewer");
	} else {
		$("#numviewers").text(num_viewers + " current viewers");
	}

	// The engine id.
	if (data['id'] && data['id']['name'] !== null) {
		$("#engineid").text(data['id']['name']);
	}

	// The score.
	if (data['score'] !== null) {
		$("#score").text(data['score']);
		var short_score = data['score'].replace(/Score: */, "");
		document.title = '(' + short_score + ') analysis.sesse.net';
	} else {
		document.title = 'analysis.sesse.net';
	}

	// The search stats.
	if (data['nodes'] && data['nps'] && data['depth']) {
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
	}

	// Update the board itself.
	fen = data['position']['fen'];
	update_displayed_line();

	if (data['position']['last_move_uci']) {
		highlight_from = data['position']['last_move_uci'].substr(0, 2);
		highlight_to = data['position']['last_move_uci'].substr(2, 2);
	} else {
		highlight_from = highlight_to = undefined;
	}
	update_highlight();

	// Print the history.
	if (data['position']['history']) {
		add_pv('start', data['position']['history'], data['position']['pretty_history'], 1, 'W', 8, true);
	} else {
		display_lines.push(null);
	}
	update_history();

	// Print the PV.
	$("#pv").html(add_pv(data['position']['fen'], data['pv_uci'], data['pv_pretty'], data['position']['move_num'], data['position']['toplay']));

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

	// Next update.
	setTimeout(function() { request_update(); }, 100);
}

/**
 * @param {boolean} sort_by_score
 */
var resort_refutation_lines = function(sort_by_score) {
	sort_refutation_lines_by_score = sort_by_score;
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
	} else {
		current_display_line = display_lines[line_num];
		current_display_move = move_num;
	}
	update_displayed_line();
	update_highlight();
	redraw_arrows();
}
window['show_line'] = show_line;

var prev_move = function() {
	if (current_display_move > -1) {
		--current_display_move;
	}
	update_displayed_line();
}
window['prev_move'] = prev_move;

var next_move = function() {
	if (current_display_line && current_display_move < current_display_line.pretty_pv.length - 1) {
		++current_display_move;
	}
	update_displayed_line();
}
window['next_move'] = next_move;

var update_displayed_line = function() {
	if (highlighted_move !== null) {
		highlighted_move.removeClass('highlight'); 
	}
	if (current_display_line === null) {
		$("#linenav").hide();
		$("#linemsg").show();
		board.position(fen);
		return;
	}

	$("#linenav").show();
	$("#linemsg").hide();

	if (current_display_move <= 0) {
		$("#prevmove").html("Previous");
	} else {
		$("#prevmove").html("<a href=\"javascript:prev_move();\">Previous</a></span>");
	}
	if (current_display_move == current_display_line.uci_pv.length - 1) {
		$("#nextmove").html("Next");
	} else {
		$("#nextmove").html("<a href=\"javascript:next_move();\">Next</a></span>");
	}

	hiddenboard.position(current_display_line.start_fen, false);
	for (var i = 0; i <= current_display_move; ++i) {
		var pos = hiddenboard.position();
		var move = current_display_line.uci_pv[i];
		var source = move.substr(0, 2);
		var target = move.substr(2, 2);
		var promo = move.substr(4, 1);

		// Check if we need to do en passant.
		var piece = pos[source];
		if (piece == "wP" || piece == "bP") {
			if (source.substr(0, 1) != target.substr(0, 1) &&
			    pos[target] === undefined) {
				var ep_square = target.substr(0, 1) + source.substr(1, 1);
				delete pos[ep_square];
				hiddenboard.position(pos, false);
			}
		}

		move = source + "-" + target;
		hiddenboard.move(move, false);
		pos = hiddenboard.position();

		// Do promotion if needed.
		if (promo != "") {
			pos[target] = pos[target].substr(0, 1) + promo.toUpperCase();
			hiddenboard.position(pos, false);
		}

		// chessboard.js does not automatically move the rook on castling
		// (issue #51; marked as won't fix), so update it ourselves.
		if (move == "e1-g1" && hiddenboard.position().g1 == "wK") {  // white O-O
			hiddenboard.move("h1-f1", false);
		} else if (move == "e1-c1" && hiddenboard.position().c1 == "wK") {  // white O-O-O
			hiddenboard.move("a1-d1", false);
		} else if (move == "e8-g8" && hiddenboard.position().g8 == "bK") {  // black O-O
			hiddenboard.move("h8-f8", false);
		} else if (move == "e8-c8" && hiddenboard.position().c8 == "bK") {  // black O-O-O
			hiddenboard.move("a8-d8", false);
		}
	}

	highlighted_move = $("#automove" + current_display_line.line_number + "-" + current_display_move);
	highlighted_move.addClass('highlight'); 

	board.position(hiddenboard.position());
}

var init = function() {
	unique = get_unique();

	// Create board.
	board = new window.ChessBoard('board', 'start');
	hiddenboard = new window.ChessBoard('hiddenboard', 'start');

	request_update();
	$(window).resize(function() {
		board.resize();
		update_highlight();
		redraw_arrows();
	});
	$(window).keyup(function(event) {
		if (event.which == 39) {
			next_move();
		} else if (event.which == 37) {
			prev_move();
		}
	});
};
$(document).ready(init);

})();
