#include <stdio.h>
#include <vector>
#include <mtbl.h>
#include <algorithm>
#include <utility>
#include <memory>
#include <string>
#include <string.h>
#include "count.h"

using namespace std;

int main(int argc, char **argv)
{
	const char *hex_prefix = argv[2];
	const int prefix_len = strlen(hex_prefix) / 2;
	uint8_t *prefix = new uint8_t[prefix_len];

	for (int i = 0; i < prefix_len; ++i) {
		char x[3];
		x[0] = hex_prefix[i * 2 + 0];
		x[1] = hex_prefix[i * 2 + 1];
		x[2] = 0;
		int k;
		sscanf(x, "%02x", &k);
		prefix[i] = k;
	}

	mtbl_reader* mtbl = mtbl_reader_init(argv[1], NULL);
	const mtbl_source *src = mtbl_reader_source(mtbl);
       	mtbl_iter *it = mtbl_source_get_prefix(src, prefix, prefix_len);

	const uint8_t *key, *val;
	size_t len_key, len_val;

	while (mtbl_iter_next(it, &key, &len_key, &val, &len_val)) {
		string move((char *)(key + prefix_len), len_key - prefix_len);
		const Count* c = (Count *)val;
		printf("%s %d %d %d %d %f %f\n", move.c_str(), c->white, c->draw, c->black, c->opening_num, c->avg_white_elo, c->avg_black_elo);
	}
}
