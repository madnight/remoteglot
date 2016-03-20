// Varnish configuration snippets.

vcl 4.0;

# You can have multiple ones; see vcl_recv.
backend analysis {
    .host = "127.0.0.1";
    .port = "5000";
}

sub vcl_recv {
    if (req.restarts == 0) {
        if (req.http.x-forwarded-for) {
            set req.http.X-Forwarded-For =
                req.http.X-Forwarded-For + ", " + client.ip;
        } else {
            set req.http.X-Forwarded-For = client.ip;
        }
    }
    if (req.http.host ~ "analysis\.sesse\.net$" && req.url ~ "^/analysis\.pl") {
        set req.backend_hint = analysis;
        # Ignored by the backend; just to identify it in vcl_backend_response.
        set req.http.x-analysis-backend = "backend1";
        return (hash);
    }
    # You can check on e.g. /analysis2\.pl here if you have multiple
    # backends; just remember to set x-analysis-backend to something unique.
}

sub vcl_deliver { 
    if (resp.http.x-analysis) {
        set resp.http.Date = now;
        unset resp.http.X-Varnish;
        unset resp.http.Via;
        unset resp.http.Age;
        unset resp.http.X-Powered-By;
    }
    unset resp.http.x-analysis;
    unset resp.http.x-analysis-backend;
}

sub vcl_hash {
    hash_data(regsub(req.url, "unique=.*$", ""));
    if (req.http.host) {
        hash_data(req.http.host);
    } else {
        hash_data(server.ip);
    }
    return (lookup);
}

sub vcl_backend_response {
    if (bereq.http.host ~ "analysis") {
        set beresp.ttl = 1m;
        if (beresp.http.content-type ~ "text" || beresp.http.content-type ~ "json") {
             set beresp.do_gzip = true;
        }
        if (bereq.url ~ "^/hash/") {
             set beresp.ttl = 5s;
             set beresp.http.x-analysis = 1;
             set beresp.http.x-analysis-backend = bereq.http.x-analysis-backend;
             return (deliver);
        }
        if (beresp.http.content-type ~ "json") {
             set beresp.http.x-analysis = 1;
             set beresp.http.x-analysis-backend = bereq.http.x-analysis-backend;
             ban ( "obj.http.x-analysis == 1 && " +
                   "obj.http.x-analysis-backend == " + bereq.http.x-analysis-backend + " && " +
                   "obj.http.x-rglm != " + beresp.http.x-rglm );
        }
        return (deliver);
    }
}
