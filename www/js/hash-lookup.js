var grpc = require('grpc');
var Chess = require(__dirname + '/chess.min.js').Chess;

var PROTO_PATH = __dirname + '/hashprobe.proto';
var hashprobe_proto = grpc.load(PROTO_PATH).hashprobe;

// TODO: Make destination configurable.
var client = new hashprobe_proto.HashProbe('localhost:50051', grpc.credentials.createInsecure());

var handle_request = function(fen, response) {
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
	var board = new Chess();

	var lines = {};

	var root = translate_line(board, fen, probe_response['root'], true);
	for (var i = 0; i < probe_response['line'].length; ++i) {
		var line = probe_response['line'][i];
		var uci_move = line['move']['from_sq'] + line['move']['to_sq'] + line['move']['promotion'];
		lines[uci_move] = translate_line(board, fen, line, false);
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

var translate_line = function(board, fen, line, pretty_score) {
	var r = {};
	board.load(fen);
	var toplay = board.turn();

	if (line['move'] && line['move']['from_sq']) {
		r['pretty_move'] = board.move({ from: line['move']['from_sq'], to: line['move']['to_sq'], promotion: line['move']['promotion'] }).san;
	} else {
		r['pretty_move'] = '';
	}
	r['sort_key'] = r['pretty_move'];
	if (!line['found']) {
		r['pv_pretty'] = [];
		r['score_sort_key'] = -100000000;
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

	// Write out the pretty score.
	// TODO: mates!
	var score = pretty_score ? 'Score: ' : '';

	if (line['bound'] === 'BOUND_UPPER') {
		score += '≤\u00a0';
	} else if (line['bound'] === 'BOUND_LOWER') {
		score += '≥\u00a0';
	}

	var value = line['value']['score_cp'];
	if (value > 0) {
		score += '+' + (value / 100.0).toFixed(2);
	} else if (value < 0) {
		score += (value / 100.0).toFixed(2);
	} else if (value == 0) {
		score += '0.00';
	} else {
		score += '';
	}
	r['pretty_score'] = score;
	r['score_sort_key'] = score_sort_key(line['value'], toplay === 'b') * 200 + r['depth'];

	return r;
}

var score_sort_key = function(score, invert) {
	if (score['score_type'] === 'SCORE_MATE') {
		var mate = score['score_mate'];
		var score;
		if (mate > 0) {
			// Side to move mates
			score = 99999 - mate;
		} else {
			// Side to move is getting mated (note the double negative for mate)
			score = -99999 - mate;
		}
		if (invert) {
			score = -score;
		}
		return score;
	} else if (score['score_type'] === 'SCORE_CP') {
		var score = score['score_cp'];
		if (invert) {
			score = -score;
		}
		return score;
	}

	return null;
}
