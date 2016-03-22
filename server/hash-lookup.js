var grpc = require('grpc');
var Chess = require('../www/js/chess.min.js').Chess;

var PROTO_PATH = __dirname + '/hashprobe.proto';
var hashprobe_proto = grpc.load(PROTO_PATH).hashprobe;

var board = new Chess();

var clients = [];

var init = function(servers) {
	for (var i = 0; i < servers.length; ++i) {
		clients.push(new hashprobe_proto.HashProbe(servers[i], grpc.credentials.createInsecure()));
	}
}
exports.init = init;

var handle_request = function(fen, response) {
	if (!board.validate_fen(fen).valid) {
		response.writeHead(400, {});
		response.end();
		return;
	}

	var rpc_status = {
		failed: false,
		left: clients.length,
		responses: [],
	}
	for (var i = 0; i < clients.length; ++i) {
		clients[i].probe({fen: fen}, function(err, probe_response) {
			if (err) {
				rpc_status.failed = true;
			} else {
				rpc_status.responses.push(probe_response);
			}
			if (--rpc_status.left == 0) {
				// All probes have come back.
				if (rpc_status.failed) {
					response.writeHead(500, {});
					response.end();
				} else {
					handle_response(fen, response, rpc_status.responses);
				}
			}
		});
	}
}
exports.handle_request = handle_request;

var handle_response = function(fen, response, probe_responses) {
	var probe_response = reconcile_responses(probe_responses);
	var lines = {};

	var root = translate_line(board, fen, probe_response['root']);
	for (var i = 0; i < probe_response['line'].length; ++i) {
		var line = probe_response['line'][i];
		var uci_move = line['move']['from_sq'] + line['move']['to_sq'] + line['move']['promotion'];
		lines[uci_move] = translate_line(board, fen, line);
	}

	var text = JSON.stringify({
		root: root,
		lines: lines
	});
	var headers = {
		'Content-Type': 'text/json; charset=utf-8'
		//'Content-Length': text.length
	};
	response.writeHead(200, headers);
	response.write(text);
	response.end();
}

var reconcile_responses = function(probe_responses) {
	var probe_response = {};

	// Select the root that has searched the deepest, plain and simple.
	probe_response['root'] = probe_responses[0]['root'];
	for (var i = 1; i < probe_responses.length; ++i) {
		var root = probe_responses[i]['root'];
		if (root['depth'] > probe_response['root']['depth']) {
			probe_response['root'] = root;
		}
	}

	// Do the same ting for each move, combining on move.
	var moves = {};
	for (var i = 0; i < probe_responses.length; ++i) {
		for (var j = 0; j < probe_responses[i]['line'].length; ++j) {
			var line = probe_responses[i]['line'][j];
			var uci_move = line['move']['from_sq'] + line['move']['to_sq'] + line['move']['promotion'];

			if (!moves[uci_move]) {
				moves[uci_move] = line;
			} else {
				moves[uci_move] = reconcile_moves(line, moves[uci_move]);
			}
		}
	}
	probe_response['line'] = [];
	for (var move in moves) {
		probe_response['line'].push(moves[move]);
	}
	return probe_response;
}

var reconcile_moves = function(a, b) {
	// Prefer exact bounds, unless the depth is just so much higher.
	if (a['bound'] === 'BOUND_EXACT' &&
	    b['bound'] !== 'BOUND_EXACT' &&
	    a['depth'] + 10 >= b['depth']) {
		return a;
	}
	if (b['bound'] === 'BOUND_EXACT' &&
	    a['bound'] !== 'BOUND_EXACT' &&
	    b['depth'] + 10 >= a['depth']) {
		return b;
	}

	if (a['depth'] > b['depth']) {
		return a;
	} else {
		return b;
	}
}	

var translate_line = function(board, fen, line) {
	var r = {};
	board.load(fen);
	var toplay = board.turn();

	if (line['move'] && line['move']['from_sq']) {
		var promo = line['move']['promotion'];
		if (promo) {
			r['pretty_move'] = board.move({ from: line['move']['from_sq'], to: line['move']['to_sq'], promotion: promo.toLowerCase() }).san;
		} else {
			r['pretty_move'] = board.move({ from: line['move']['from_sq'], to: line['move']['to_sq'] }).san;
		}
	} else {
		r['pretty_move'] = '';
	}
	r['sort_key'] = r['pretty_move'];
	if (!line['found']) {
		r['pv_pretty'] = [];
		return r;
	}
	r['depth'] = line['depth'];

	// Convert the PV.
	var pv = [];
	if (r['pretty_move']) {
		pv.push(r['pretty_move']);
	}
	for (var j = 0; j < line['pv'].length; ++j) {
		var move = line['pv'][j];
		var decoded = board.move({ from: move['from_sq'], to: move['to_sq'], promotion: move['promotion'] });
		if (decoded === null) {
			break;
		}
		pv.push(decoded.san);
	}
	r['pv_pretty'] = pv;

	// Convert the score. Use the static eval if no search.
	var value = line['value'] || line['eval'];
	var score = null;
	if (value['score_type'] === 'SCORE_CP') {
		score = ['cp', value['score_cp']];
	} else if (value['score_type'] === 'SCORE_MATE') {
		score = ['m', value['score_mate']];
	}
	if (score) {
		if (line['bound'] === 'BOUND_UPPER') {
			score.push('≤');
		} else if (line['bound'] === 'BOUND_LOWER') {
			score.push('≥');
		}
	}

	r['score'] = score;

	return r;
}
