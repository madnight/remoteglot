// node.js version of analysis.pl; hopefully scales a bit better
// for this specific kind of task.

// Modules.
var http = require('http');
var fs = require('fs');
var url = require('url');
var querystring = require('querystring');
var path = require('path');
var zlib = require('zlib');
var delta = require('./js/json_delta.js');

// Constants.
var JSON_FILENAME = '/srv/analysis.sesse.net/www/analysis.json';
var HISTORY_TO_KEEP = 5;
var MINIMUM_VERSION = null;

// TCP port to listen on; can be overridden with flags.
var port = 5000;

// If set to 1, we are already processing a JSON update and should not
// start a new one. If set to 2, we are _also_ having one in the queue.
var json_lock = 0;

// The current contents of the file to hand out, and its last modified time.
var json = undefined;

// The last five timestamps, and diffs from them to the latest version.
var historic_json = [];
var diff_json = {};

// The list of clients that are waiting for new data to show up.
// Uniquely keyed by request_id so that we can take them out of
// the queue if they close the socket.
var sleeping_clients = {};
var request_id = 0;

// List of when clients were last seen, keyed by their unique ID.
// Used to show a viewer count to the user.
var last_seen_clients = {};

// The timer used to touch the file every 30 seconds if nobody
// else does it for us. This makes sure we don't have clients
// hanging indefinitely (which might have them return errors).
var touch_timer = undefined;

// If we are behind Varnish, we can't count the number of clients
// ourselves, so some external log-tailing daemon needs to tell us.
var viewer_count_override = undefined;

var replace_json = function(new_json_contents, mtime) {
	// Generate the list of diffs from the last five versions.
	if (json !== undefined) {
		// If two versions have the same mtime, clients could have either.
		// Note the fact, so that we never insert it.
		if (json.last_modified == mtime) {
			json.invalid_base = true;
		}
		if (!json.invalid_base) {
			historic_json.push(json);
			if (historic_json.length > HISTORY_TO_KEEP) {
				historic_json.shift();
			}
		}
	}

	var new_json = {
		parsed: JSON.parse(new_json_contents),
		plain: new_json_contents,
		last_modified: mtime
	};
	create_json_historic_diff(new_json, historic_json.slice(0), {}, function(new_diff_json) {
		// gzip the new version (non-delta), and put it into place.
		zlib.gzip(new_json_contents, function(err, buffer) {
			if (err) throw err;

			new_json.gzip = buffer;
			json = new_json;
			diff_json = new_diff_json;
			json_lock = 0;

			// Finally, wake up any sleeping clients.
			possibly_wakeup_clients();
		});
	});
}

var create_json_historic_diff = function(new_json, history_left, new_diff_json, cb) {
	if (history_left.length == 0) {
		cb(new_diff_json);
		return;
	}

	var histobj = history_left.shift();
	var diff = delta.JSON_delta.diff(histobj.parsed, new_json.parsed);
	var diff_text = JSON.stringify(diff);
	zlib.gzip(diff_text, function(err, buffer) {
		if (err) throw err;
		new_diff_json[histobj.last_modified] = {
			parsed: diff,
			plain: diff_text,
			gzip: buffer,
			last_modified: new_json.last_modified,
		};
		create_json_historic_diff(new_json, history_left, new_diff_json, cb);
	});
}

var reread_file = function(event, filename) {
	if (filename != path.basename(JSON_FILENAME)) {
		return;
	}
	if (json_lock >= 2) {
		return;
	}
	if (json_lock == 1) {
		// Already processing; wait a bit.
		json_lock = 2;
		setTimeout(function() { json_lock = 1; reread_file(event, filename); }, 100);
		return;
	}
	json_lock = 1;

	console.log("Rereading " + JSON_FILENAME);
	fs.open(JSON_FILENAME, 'r+', function(err, fd) {
		if (err) throw err;
		fs.fstat(fd, function(err, st) {
			if (err) throw err;
			var buffer = new Buffer(1048576);
			fs.read(fd, buffer, 0, 1048576, 0, function(err, bytesRead, buffer) {
				if (err) throw err;
				fs.close(fd, function() {
					var new_json_contents = buffer.toString('utf8', 0, bytesRead);
					replace_json(new_json_contents, st.mtime.getTime());
				});
			});
		});
	});

	if (touch_timer !== undefined) {
		clearTimeout(touch_timer);
	}
	touch_timer = setTimeout(function() {
		console.log("Touching analysis.json due to no other activity");
		var now = Date.now() / 1000;
		fs.utimes(JSON_FILENAME, now, now);
	}, 30000);
}
var possibly_wakeup_clients = function() {
	var num_viewers = count_viewers();
	for (var i in sleeping_clients) {
		mark_recently_seen(sleeping_clients[i].unique);
		send_json(sleeping_clients[i].response,
		          sleeping_clients[i].ims,
		          sleeping_clients[i].accept_gzip,
			  num_viewers);
	}
	sleeping_clients = {};
}
var send_404 = function(response) {
	response.writeHead(404, {
		'Content-Type': 'text/plain',
	});
	response.write('Something went wrong. Sorry.');
	response.end();
}
var handle_viewer_override = function(request, u, response) {
	// Only accept requests from localhost.
	var peer = request.socket.localAddress;
	if ((peer != '127.0.0.1' && peer != '::1') || request.headers['x-forwarded-for']) {
		console.log("Refusing viewer override from " + peer);
		send_404(response);
	} else {
		viewer_count_override = (u.query)['num'];
		response.writeHead(200, {
			'Content-Type': 'text/plain',
		});
		response.write('OK.');
		response.end();
	}
}
var send_json = function(response, ims, accept_gzip, num_viewers) {
	var this_json = diff_json[ims] || json;

	var headers = {
		'Content-Type': 'text/json',
		'X-RGLM': this_json.last_modified,
		'X-RGNV': num_viewers,
		'Access-Control-Expose-Headers': 'X-RGLM, X-RGNV, X-RGMV',
		'Vary': 'Accept-Encoding',
	};

	if (MINIMUM_VERSION) {
		headers['X-RGMV'] = MINIMUM_VERSION;
	}

	if (accept_gzip) {
		headers['Content-Length'] = this_json.gzip.length;
		headers['Content-Encoding'] = 'gzip';
		response.writeHead(200, headers);
		response.write(this_json.gzip);
	} else {
		headers['Content-Length'] = this_json.plain.length;
		response.writeHead(200, headers);
		response.write(this_json.plain);
	}
	response.end();
}
var mark_recently_seen = function(unique) {
	if (unique) {
		last_seen_clients[unique] = (new Date).getTime();
	}
}
var count_viewers = function() {
	if (viewer_count_override !== undefined) {
		return viewer_count_override;
	}

	var now = (new Date).getTime();

	// Go through and remove old viewers, and count them at the same time.
	var new_last_seen_clients = {};
	var num_viewers = 0;
	for (var unique in last_seen_clients) {
		if (now - last_seen_clients[unique] < 5000) {
			++num_viewers;
			new_last_seen_clients[unique] = last_seen_clients[unique];
		}
	}

	// Also add sleeping clients that we would otherwise assume timed out.
	for (var request_id in sleeping_clients) {
		var unique = sleeping_clients[request_id].unique;
		if (unique && !(unique in new_last_seen_clients)) {
			++num_viewers;
		}
	}

	last_seen_clients = new_last_seen_clients;
	return num_viewers;
}

// Set up a watcher to catch changes to the file, then do an initial read
// to make sure we have a copy.
fs.watch(path.dirname(JSON_FILENAME), reread_file);
reread_file(null, path.basename(JSON_FILENAME));

var server = http.createServer();
server.on('request', function(request, response) {
	var u = url.parse(request.url, true);
	var ims = (u.query)['ims'];
	var unique = (u.query)['unique'];

	console.log(((new Date).getTime()*1e-3).toFixed(3) + " " + request.url);
	if (u.pathname === '/override-num-viewers') {
		handle_viewer_override(request, u, response);
		return;
	}
	if (u.pathname !== '/analysis.pl') {
		// This is not the request you are looking for.
		send_404(response);
		return;
	}

	mark_recently_seen(unique);

	var accept_encoding = request.headers['accept-encoding'];
	var accept_gzip;
	if (accept_encoding !== undefined && accept_encoding.match(/\bgzip\b/)) {
		accept_gzip = true;
	} else {
		accept_gzip = false;
	}

	// If we already have something newer than what the user has,
	// just send it out and be done with it.
	if (json !== undefined && (!ims || json.last_modified > ims)) {
		send_json(response, ims, accept_gzip, count_viewers());
		return;
	}

	// OK, so we need to hang until we have something newer.
	// Put the user on the wait list.
	var client = {};
	client.response = response;
	client.request_id = request_id;
	client.accept_gzip = accept_gzip;
	client.unique = unique;
	client.ims = ims;
	sleeping_clients[request_id++] = client;

	request.socket.client = client;
});
server.on('connection', function(socket) {
	socket.on('close', function() {
		var client = socket.client;
		if (client) {
			mark_recently_seen(client.unique);
			delete sleeping_clients[client.request_id];
		}
	});
});

if (process.argv.length >= 3) {
	port = parseInt(process.argv[2]);
}
server.listen(port);
