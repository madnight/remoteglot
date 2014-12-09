#include <stdio.h>
#include <mtbl.h>
#include <memory>
#include <string>
#include <string.h>
#include <assert.h>
#include "count.h"

using namespace std;


void merge_count(void* userdata,
                 const uint8_t *key, size_t len_key,
		 const uint8_t *val0, size_t len_val0,
		 const uint8_t *val1, size_t len_val1,
		 uint8_t **merged_val, size_t *len_merged_val)
{
	assert(len_val0 == sizeof(Count));
	assert(len_val1 == sizeof(Count));

	const Count* c0 = reinterpret_cast<const Count*>(val0);
	const Count* c1 = reinterpret_cast<const Count*>(val1);
	unique_ptr<Count> c((Count *)malloc(sizeof(Count)));  // Needs to be with malloc, per merger spec.

	c->white = c0->white + c1->white;
	c->draw = c0->draw + c1->draw;
	c->black = c0->black + c1->black;
	c->opening_num = c0->opening_num;  // Arbitrary choice.
	c->sum_white_elo = c0->sum_white_elo + c1->sum_white_elo;
	c->sum_black_elo = c0->sum_black_elo + c1->sum_black_elo;
	c->num_elo = c0->num_elo + c1->num_elo;

	*merged_val = reinterpret_cast<uint8_t *>(c.release());
	*len_merged_val = sizeof(Count);
}

int main(int argc, char **argv)
{
	mtbl_merger_options* mopt = mtbl_merger_options_init();
	mtbl_merger_options_set_merge_func(mopt, merge_count, NULL);
	mtbl_merger* merger = mtbl_merger_init(mopt);

	for (int i = 1; i < argc - 1; ++i) {
		mtbl_reader* mtbl = mtbl_reader_init(argv[i], NULL);
		mtbl_merger_add_source(merger, mtbl_reader_source(mtbl));
	}

	mtbl_writer* writer = mtbl_writer_init(argv[argc - 1], NULL);
	mtbl_source_write(mtbl_merger_source(merger), writer);
	mtbl_writer_destroy(&writer);
}
