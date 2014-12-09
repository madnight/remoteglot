//#define _GLIBCXX_PARALLEL

// Usage: ./binloader IN1 IN2 IN3 ... OUT

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

enum Result { WHITE = 0, DRAW, BLACK };
struct Element {
	string bpfen_and_move;
	Result result;
	int opening_num, white_elo, black_elo;

	bool operator< (const Element& other) const {
		return bpfen_and_move < other.bpfen_and_move;
	}
};

int main(int argc, char **argv)
{
	vector<Element> elems;

	for (int i = 1; i < argc - 1; ++i) {
		FILE *fp = fopen(argv[i], "rb");
		if (fp == NULL) {
			perror(argv[i]);
			exit(1);
		}
		for ( ;; ) {
			int l = getc(fp);
			if (l == -1) {
				break;
			}
		
			string bpfen_and_move;
			bpfen_and_move.resize(l);
			if (fread(&bpfen_and_move[0], l, 1, fp) != 1) {
				perror("fread()");
		//		exit(1);
				break;
			}

			int r = getc(fp);
			if (r == -1) {
				perror("getc()");
				//exit(1);
				break;
			}

			int opening_num, white_elo, black_elo;
			if (fread(&white_elo, sizeof(white_elo), 1, fp) != 1) {
				perror("fread()");
				//exit(1);
				break;
			}
			if (fread(&black_elo, sizeof(black_elo), 1, fp) != 1) {
				perror("fread()");
				//exit(1);
				break;
			}
			if (fread(&opening_num, sizeof(opening_num), 1, fp) != 1) {
				perror("fread()");
				//exit(1);
				break;
			}
			elems.emplace_back(Element {move(bpfen_and_move), Result(r), opening_num, white_elo, black_elo});
		}
		fclose(fp);

		printf("Read %ld elems\n", elems.size());
	}

	printf("Sorting...\n");
	sort(elems.begin(), elems.end());

	printf("Writing SSTable...\n");
	mtbl_writer_options* wopt = mtbl_writer_options_init();
	mtbl_writer_options_set_compression(wopt, MTBL_COMPRESSION_SNAPPY);
	mtbl_writer* mtbl = mtbl_writer_init(argv[argc - 1], wopt);
	Count c;
	for (int i = 0; i < elems.size(); ++i) {
		if (elems[i].result == WHITE) {
			++c.white;
		} else if (elems[i].result == DRAW) {
			++c.draw;
		} else if (elems[i].result == BLACK) {
			++c.black;
		}
		c.opening_num = elems[i].opening_num;
		if (elems[i].white_elo >= 100 && elems[i].black_elo >= 100) {
			c.sum_white_elo += elems[i].white_elo;
			c.sum_black_elo += elems[i].black_elo;
			++c.num_elo;
		}
		if (i == elems.size() - 1 || elems[i].bpfen_and_move != elems[i + 1].bpfen_and_move) {
			mtbl_writer_add(mtbl,
				(const uint8_t *)elems[i].bpfen_and_move.data(), elems[i].bpfen_and_move.size(),
				(const uint8_t *)&c, sizeof(c));
			c = Count();
		}
	}
	mtbl_writer_destroy(&mtbl);
}
