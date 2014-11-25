/* JSON-delta v0.2 - A diff/patch pair for JSON-serialized data structures.

Copyright 2013-2014 Philip J. Roberts <himself@phil-roberts.name>.
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

This implementation is based heavily on the original python2 version:
see http://www.phil-roberts.name/json-delta/ for further
documentation.  */
JSON_delta = {
    isStrictlyEqual: function (left, right) {
	if (this.isTerminal(left) && this.isTerminal(right)) {
	    return (left === right);
	}
	if (this.isTerminal(left) || this.isTerminal(right)) {
	    return false;
	}
	if (left instanceof Array && right instanceof Array) {
	    if (left.length != right.length) {
		return false;
	    }
	    for (idx in left) {
		if ( ! this.isStrictlyEqual(left[idx], right[idx])) {
		    return false;
		}
	    }
	    return true;
	}
	if (left instanceof Array || right instanceof Array) {
	    return false;
	}
	var ks = this.computeKeysets(left, right);
	if (ks[1].length != 0 || ks[2].length != 0) {
	    return false;
	}
	for (key in ks[0]) {
	    key = ks[0][key];
	    if ( ! this.isStrictlyEqual(left[key], right[key])) {
		return false
	    }
	}
	return true;
    },

    isTerminal: function (obj) {
	if (typeof obj == "string" || typeof obj == "number"
	    || typeof obj == "boolean" || obj == null) {
	    return true;
	}
	return false;
    },

    splitDeletions: function (diff) {
	if (diff.length == 0) {return [[], diff]}
	diff.sort(function (a,b) {return b.length-a.length});
	for (idx in diff) {
	    if (diff[idx] > 1) {break}
	}
	return [diff.slice(0,idx), diff.slice(idx)]
    },

    sortStanzas: function (diff) {
	// Sorts the stanzas in a diff: node changes can occur in any
	// order, but deletions from sequences have to happen last node
	// first: ['foo', 'bar', 'baz'] -> ['foo', 'bar'] -> ['foo'] ->
	// [] and additions to sequences have to happen
	// leftmost-node-first: [] -> ['foo'] -> ['foo', 'bar'] ->
	// ['foo', 'bar', 'baz'].


	// First we divide the stanzas using splitDeletions():
	var split_thing = this.splitDeletions(diff);
	// Then we sort modifications in ascending order of last key:
	split_thing[0].sort(function (a,b) {return a[0].slice(-1)[0]-b[0].slice(-1)[0]});
	// And deletions in descending order of last key:
	split_thing[1].sort(function (a,b) {return b[0].slice(-1)[0]-a[0].slice(-1)[0]});
	// And recombine:
	return split_thing[0].concat(split_thing[1])
    },

    computeKeysets: function (left, right) {
	/* Returns an array of three arrays (overlap, left_only,
	 * right_only), representing the properties common to left and
	 * right, only defined for left, and only defined for right,
	 * respectively. */
	var overlap = [], left_only = [], right_only = [];
	var target = overlap;
	var targ_num = (left instanceof Array);

	for (key in left) {
	    if (targ_num) {
		key = Number(key)
	    }
	    if (key in right) {
		target = overlap;
	    }
	    else {
		target = left_only;
	    }
	    target.push(key);
	}
	for (key in right) {
	    if (targ_num) {
		key = Number(key)
	    }
	    if (! (key in left)) {
		right_only.push(key);
	    }
	}
	return [overlap, left_only, right_only]
    },

    commonality: function (left, right) {
	var com = 0;
	var tot = 0;
	if (this.isTerminal(left) || this.isTerminal(right)) {
	    return 0;
	}

	if ((left instanceof Array) && (right instanceof Array)) {
	    for (idx in left) {
		elem = left[idx];
		if (right.indexOf(elem) != -1) {
		    com += 1;
		}
	    }
	    tot = Math.max(left.length, right.length);
	}
	else if ((left instanceof Array) || (right instanceof Array)) {
	    return 0;
	}
	else {
            var ks = this.computeKeysets(left, right);
            o = ks[0]; l = ks[1]; r = ks[2];
	    com = o.length;
	    tot = o.length + l.length + r.length;
	    for (idx in r) {
		elem = r[idx];
		if (l.indexOf(elem) == -1) {
		    tot += 1
		}
	    }
	}
	if (tot == 0) {return 0}
	return com / tot;
    },

    thisLevelDiff: function (left, right, key, common) {
	// Returns a sequence of diff stanzas between the objects left and
	// right, assuming that they are each at the position key within
	// the overall structure.
	var out = [];
	key = typeof key !== 'undefined' ? key: [];

	if (typeof common == 'undefined') {
	    common = this.commonality(left, right);
	}

	if (common) {
	    var ks = this.computeKeysets(left, right);
	    for (idx in ks[0]) {
		okey = ks[0][idx];
		if (left[okey] != right[okey]) {
		    out.push([key.concat([okey]), right[okey]]);
		}
	    }
	    for (idx in ks[1]) {
		okey = ks[1][idx];
		out.push([key.concat([okey])]);
	    }
	    for (idx in ks[2]) {
		okey = ks[2][idx];
		out.push([key.concat([okey]), right[okey]]);
	    }
	    return out
	}
	else if ( ! this.isStrictlyEqual(left,right)) {
	    return [[key, right]]
	}
	else {
	    return []
	}
    },

    keysetDiff: function (left, right, key) {
	var out = [];
	var ks = this.computeKeysets(left, right);
	for (k in ks[1]) {
	    out.push([key.concat(ks[1][k])]);
	}
	for (k in ks[2]) {
	    out.push([key.concat(ks[2][k]), right[ks[2][k]]]);
	}
	for (k in ks[0]) {
	    out = out.concat(this.diff(left[ks[0][k]], right[ks[0][k]],
				       key.concat([ks[0][k]])))
	}
	return out;
    },

    patchStanza: function (struc, diff) {
	// Applies the diff stanza diff to the structure struc.  Returns
	// the modified structure.
	key = diff[0];
	switch (key.length) {
	case 0:
	    struc = diff[1];
	    break;
	case 1:
	    if (diff.length == 1) {
		if (typeof struc.splice == 'undefined') {
		    delete struc[key[0]];
		}
		else {
		    struc.splice(key[0], 1);
		}
	    }
	    else {
		struc[key[0]] = diff[1];
	    }
	    break;
	default:
	    pass_key = key.slice(1);
	    pass_struc = struc[key[0]];
	    pass_diff = [pass_key].concat(diff.slice(1));
	    struc[key[0]] = this.patchStanza(pass_struc, pass_diff);
	}
	return struc;
    },

    patch: function (struc, diff) {
	// Applies the sequence of diff stanzas diff to the structure
	// struc, and returns the patched structure.
	for (stan_key in diff) {
	    struc = this.patchStanza(struc, diff[stan_key]);
	}
	return struc
    },

    diff: function (left, right, key, minimal) {
	key = typeof key !== 'undefined' ? key : [];
	minimal = typeof minimal !== 'undefined' ? minimal: true;
	var dumbdiff = [[key, right]]
	var my_diff = [];

	common = this.commonality(left, right);
	if (common < 0.5) {
	    my_diff = this.thisLevelDiff(left, right, key, common);
	}
	else {
	    my_diff = this.keysetDiff(left, right, key);
	}

	if (minimal) {
	    if (JSON.stringify(dumbdiff).length <
		JSON.stringify(my_diff).length) {
		my_diff = dumbdiff
	    }
	}

	if (key.length == 0) {
	    if (my_diff.length > 1) {
		my_diff = this.sortStanzas(my_diff);
	    }
	}
	return my_diff;
    }
}

// node.js
if (typeof exports !== 'undefined') exports.JSON_delta = JSON_delta;
