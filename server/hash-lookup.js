var grpc = require('grpc');
var Chess = require('../www/js/chess.min.js').Chess;

var PROTO_PATH = __dirname + '/hashprobe.proto';
var hashprobe_proto = grpc.load(PROTO_PATH).hashprobe;

// TODO: Make destination configurable.
var client = new hashprobe_proto.HashProbe('localhost:50051', grpc.credentials.createInsecure());

var board = new Chess();

var handle_request = function(fen, response) {
	if (!board.validate_fen(fen).valid) {
		response.writeHead(400, {});
		response.end();
		return;
	}
	client.probe({fen: fen}, function(err, probe_response) {
		if (err) {
			response.writeHead(500, {});
			response.end();
		} else {
			handle_response(fen, response, probe_response);
		}
	});
}
exports.handle_request = handle_request;

var handle_response = function(fen, response, probe_response) {
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
