// node.js version of analysis.pl; hopefully scales a bit better
// for this specific kind of task.

// Modules.
var http = require('http');
var fs = require('fs');
var url = require('url');
var querystring = require('querystring');
var path = require('path');
var zlib = require('zlib');
var readline = require('readline');
var child_process = require('child_process');
var delta = require('../www/js/json_delta.js');
var hash_lookup = require('./hash-lookup.js');

// Constants.
var HISTORY_TO_KEEP = 5;
var MINIMUM_VERSION = null;
var COUNT_FROM_VARNISH_LOG = true;

// Filename to serve.
var json_filename = '/srv/analysis.sesse.net/www/analysis.json';
if (process.argv.length >= 3) {
	json_filename = process.argv[2];
}

// Expected destination filenames.
var serve_url = '/analysis.pl';
var hash_serve_url = '/hash';
if (process.argv.length >= 4) {
	serve_url = process.argv[3];
}
if (process.argv.length >= 5) {
	hash_serve_url = process.argv[4];
}

// TCP port to listen on.
var port = 5000;
if (process.argv.length >= 6) {
	port = parseInt(process.argv[5]);
}

// gRPC backends.
var grpc_backends = ["localhost:50051", "localhost:50052"];
if (process.argv.length >= 7) {
	grpc_backends = process.argv[6].split(",");
}
hash_lookup.init(grpc_backends);

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
// ourselves, so we need to get it from parsing varnishncsa.
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
	if (filename != path.basename(json_filename)) {
		return;
	}
	if (json_lock >= 2) {
		return;
	}
	if (json_lock == 1) {
		// Already processing; wait a bit.
		json_lock = 2;
		setTimeout(function() { if (json_lock == 2) json_lock = 1; reread_file(event, filename); }, 100);
		return;
	}
	json_lock = 1;

	console.log("Rereading " + json_filename);
	fs.open(json_filename, 'r', function(err, fd) {
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
		fs.utimes(json_filename, now, now);
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
var log = function(str) {
	console.log("[" + ((new Date).getTime()*1e-3).toFixed(3) + "] " + str);
}

// Set up a watcher to catch changes to the file, then do an initial read
// to make sure we have a copy.
fs.watch(path.dirname(json_filename), reread_file);
reread_file(null, path.basename(json_filename));

if (COUNT_FROM_VARNISH_LOG) {
	// Note: We abuse serve_url as a regex.
	var varnishncsa = child_process.spawn(
		'varnishncsa', ['-F', '%{%s}t %U %q tffb=%{Varnish:time_firstbyte}x',
		'-q', 'ReqURL ~ "^' + serve_url + '"']);
	var rl = readline.createInterface({
		input: varnishncsa.stdout,
		output: varnishncsa.stdin,
		terminal: false
	});

	var uniques = [];
	rl.on('line', function(line) {
		var v = line.match(/(\d+) .*\?ims=\d+&unique=(.*) tffb=(.*)/);
		if (v) {
			uniques[v[2]] = {
				last_seen: (parseInt(v[1]) + parseFloat(v[3])) * 1e3,
				grace: null,
			};
			log(v[1] + " " + v[2] + " " + v[3]);
		} else {
			log("VARNISHNCSA UNPARSEABLE LINE: " + line);
		}
	});
	setInterval(function() {
		var mtime = json.last_modified - 1000;  // Compensate for subsecond issues.
		var now = (new Date).getTime();
		var num_viewers = 0;

		for (var unique in uniques) {
			++num_viewers;
			var last_seen = uniques[unique].last_seen;
			if (now - last_seen <= 5000) {
				// We've seen this user in the last five seconds;
				// it's okay.
				continue;
			}
			if (last_seen >= mtime) {
				// This user has the latest version;
				// they are probably just hanging.
				continue;
			}
			if (uniques[unique].grace === null) {
				// They have five seconds after a new JSON has been
				// provided to get get it, or they're out.
				// We don't simply use mtime, since we don't want to
				// reset the grace timer just because a new JSON is
				// published.
				uniques[unique].grace = mtime;
			}
			if (now - uniques[unique].grace > 5000) {
				log("Timing out " + unique + " (last_seen=" + last_seen + ", now=" + now +
					", mtime=" + mtime, ", grace=" + uniques[unique].grace + ")");
				delete uniques[unique];
				--num_viewers;
			}
		}

		log(num_viewers + " entries in hash, mtime=" + mtime);
		viewer_count_override = num_viewers;
	}, 1000);
}

var server = http.createServer();
server.on('request', function(request, response) {
	var u = url.parse(request.url, true);
	var ims = (u.query)['ims'];
	var unique = (u.query)['unique'];

	log(request.url);
	if (u.pathname === hash_serve_url) {
		var fen = (u.query)['fen'];
		hash_lookup.handle_request(fen, response);
		return;
	}
	if (u.pathname !== serve_url) {
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

server.listen(port);
