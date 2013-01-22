#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <fcntl.h>

#define DUMP_FEN 0
#define DUMP_ENC 0

int cto_fd, ctg_fd, ctb_fd;

unsigned int tbl2[] = {
	0x3100d2bf, 0x3118e3de, 0x34ab1372, 0x2807a847,
	0x1633f566, 0x2143b359, 0x26d56488, 0x3b9e6f59,
	0x37755656, 0x3089ca7b, 0x18e92d85, 0x0cd0e9d8,
	0x1a9e3b54, 0x3eaa902f, 0x0d9bfaae, 0x2f32b45b,
	0x31ed6102, 0x3d3c8398, 0x146660e3, 0x0f8d4b76,
	0x02c77a5f, 0x146c8799, 0x1c47f51f, 0x249f8f36,
	0x24772043, 0x1fbc1e4d, 0x1e86b3fa, 0x37df36a6,
	0x16ed30e4, 0x02c3148e, 0x216e5929, 0x0636b34e,
	0x317f9f56, 0x15f09d70, 0x131026fb, 0x38c784b1,
	0x29ac3305, 0x2b485dc5, 0x3c049ddc, 0x35a9fbcd,
	0x31d5373b, 0x2b246799, 0x0a2923d3, 0x08a96e9d,
	0x30031a9f, 0x08f525b5, 0x33611c06, 0x2409db98,
	0x0ca4feb2, 0x1000b71e, 0x30566e32, 0x39447d31,
	0x194e3752, 0x08233a95, 0x0f38fe36, 0x29c7cd57,
	0x0f7b3a39, 0x328e8a16, 0x1e7d1388, 0x0fba78f5,
	0x274c7e7c, 0x1e8be65c, 0x2fa0b0bb, 0x1eb6c371
};

signed char data[] = {
	0x36, 0xb6, 0x0f, 0x79, 0x61, 0x1f, 0x50, 0xde, 0x61, 0xb9, 0x52, 0x24, 0xb3, 0xac, 0x6e, 0x5e, 0x0a, 0x69, 0xbd, 0x61, 0x61, 0xc5
};

void output_stats(char *result, int invert)
{
	unsigned char *ptr = result;
	ptr += *ptr;
	ptr += 3;

	// wins-draw-loss
	if (invert) {
		printf("%u,", (ptr[0] << 16) | (ptr[1] << 8) | ptr[2]);
		printf("%u,", (ptr[6] << 16) | (ptr[7] << 8) | ptr[8]);
		printf("%u,", (ptr[3] << 16) | (ptr[4] << 8) | ptr[5]);
	} else {
		printf("%u,", (ptr[3] << 16) | (ptr[4] << 8) | ptr[5]);
		printf("%u,", (ptr[6] << 16) | (ptr[7] << 8) | ptr[8]);
		printf("%u,", (ptr[0] << 16) | (ptr[1] << 8) | ptr[2]);
	}

	ptr += 9;
	ptr += 4;
	ptr += 7;

	// rating
	{
		int rat2_sum, rat2_div;
		rat2_div = (ptr[0] << 16) | (ptr[1] << 8) | ptr[2];
		rat2_sum = (ptr[3] << 24) | (ptr[4] << 16) | (ptr[5] << 8) | ptr[6];

		if (rat2_div == 0) {
			printf(",0");
		} else {
			printf("%u,%u", rat2_sum / rat2_div, rat2_div);
		}
	}
		
	printf("\n");
}

unsigned int gen_hash(signed char *ptr, unsigned len)
{
	signed hash = 0;
	short tmp = 0;
	int i;

	for (i = 0; i < len; ++i) {
		signed char ch = *ptr++;
		tmp += ((0x0f - (ch & 0x0f)) << 2) + 1;
		hash += tbl2[tmp & 0x3f];
		tmp += ((0xf0 - (ch & 0xf0)) >> 2) + 1;
		hash += tbl2[tmp & 0x3f];
	}
	return hash;
}

void decode_fen_board(char *str, char *board)
{
	while (*str) {
		switch (*str) {
		case 'r':
		case 'n':
		case 'b':
		case 'q':
		case 'k':
		case 'p':
		case 'R':
		case 'N':
		case 'B':
		case 'Q':
		case 'K':
		case 'P':
			*board++ = *str;
			break;
		case '8':
			*board++ = ' ';
			// fall through
		case '7':
			*board++ = ' ';
			// fall through
		case '6':
			*board++ = ' ';
			// fall through
		case '5':
			*board++ = ' ';
			// fall through
		case '4':
			*board++ = ' ';
			// fall through
		case '3':
			*board++ = ' ';
			// fall through
		case '2':
			*board++ = ' ';
			// fall through
		case '1':
			*board++ = ' ';
			break;
		case '/':
			// ignore
			break;
		default:
			fprintf(stderr, "Unknown FEN board character '%c'\n", *str);
			exit(1);
		}

		++str;
	}
}

void invert_board(char *board)
{
	int y, x, i;

	// flip the board
	for (y = 0; y < 4; ++y) {
		for (x = 0; x < 8; ++x) {
			char tmp = board[y * 8 + (x)];
			board[y * 8 + (x)] = board[(7-y) * 8 + (x)];
			board[(7-y) * 8 + (x)] = tmp;
		}
	}

	// invert the colors
	for (y = 0; y < 8; ++y) {
		for (x = 0; x < 8; ++x) {
			if (board[y * 8 + x] == toupper(board[y * 8 + x])) {
				board[y * 8 + x] = tolower(board[y * 8 + x]);
			} else {
				board[y * 8 + x] = toupper(board[y * 8 + x]);
			}
		}
	}
}

int needs_flipping(char *board, char *castling_rights)
{
	int y, x;

	// never flip if either side can castle
	if (strcmp(castling_rights, "-") != 0)
		return 0;

	for (y = 0; y < 8; ++y) {
		for (x = 0; x < 4; ++x) {
			if (board[y * 8 + x] == 'K')
				return 1;
		}
	}

	return 0;
}

// horizontal flip
void flip_board(char *board, char *eps)
{
	int y, x;

	// flip the board
	for (y = 0; y < 8; ++y) {
		for (x = 0; x < 4; ++x) {
			char tmp = board[y * 8 + x];
			board[y * 8 + (x)] = board[y * 8 + (7-x)];
			board[y * 8 + (7-x)] = tmp;
		}
	}

	// flip the en passant square
	if (strcmp(eps, "-") != 0) {
		int epsc = eps[0] - 'a';
		eps[0] = 'a' + (7 - epsc);
	}
}

unsigned char position[32];
int pos_len;
int bits_left;

void put_bit(int x)
{
	position[pos_len] <<= 1;
	if (x)
		position[pos_len] |= 1;

	if (--bits_left == 0) {
		++pos_len;
		bits_left = 8;
	}
}

void dump_fen(char *board, int invert, int flip, char *castling_rights, char *ep_square)
{
	int y, x;
	for (y = 0; y < 8; ++y) {
		int space = 0;
		for (x = 0; x < 8; ++x) {
			int xx = (flip) ? (7-x) : x;

			if (board[y * 8 + xx] == ' ') {
				++space;
			} else {
				if (space != 0)
					putchar('0' + space);
				putchar(board[y * 8 + xx]);
				space = 0;
			}
		}
		if (space != 0)
			putchar('0' + space);
		if (y != 7)
			putchar('/');
	}
	putchar(' ');

	if (invert)
		putchar('b');
	else
		putchar('w');

	printf(" %s ", castling_rights);
	if (flip && strcmp(ep_square, "-") != 0) {
		printf("%c%c 0 0\n", 'a' + (7 - (ep_square[0] - 'a')), ep_square[1]);
	} else {
		printf("%s 0 0\n", ep_square);
	}
}

void encode_position(char *board, int invert, char *castling_rights, char *ep_column)
{
	int x, y;
	int ep_any = 0;

	// clear out
	memset(position, 0, 32);

	// leave some room for the header byte, which will be filled last
	pos_len = 1;
	bits_left = 8;

	// slightly unusual ordering
	for (x = 0; x < 8; ++x) {
		for (y = 0; y < 8; ++y) {
			switch (board[(7-y) * 8 + x]) {
			case ' ':
				put_bit(0);
				break;
			case 'p':
				put_bit(1);
				put_bit(1);
				put_bit(1);
				break;
			case 'P':
				put_bit(1);
				put_bit(1);
				put_bit(0);
				break;
			case 'r':
				put_bit(1);
				put_bit(0);
				put_bit(1);
				put_bit(1);
				put_bit(1);
				break;
			case 'R':
				put_bit(1);
				put_bit(0);
				put_bit(1);
				put_bit(1);
				put_bit(0);
				break;
			case 'b':
				put_bit(1);
				put_bit(0);
				put_bit(1);
				put_bit(0);
				put_bit(1);
				break;
			case 'B':
				put_bit(1);
				put_bit(0);
				put_bit(1);
				put_bit(0);
				put_bit(0);
				break;
			case 'n':
				put_bit(1);
				put_bit(0);
				put_bit(0);
				put_bit(1);
				put_bit(1);
				break;
			case 'N':
				put_bit(1);
				put_bit(0);
				put_bit(0);
				put_bit(1);
				put_bit(0);
				break;
			case 'q':
				put_bit(1);
				put_bit(0);
				put_bit(0);
				put_bit(0);
				put_bit(1);
				put_bit(1);
				break;
			case 'Q':
				put_bit(1);
				put_bit(0);
				put_bit(0);
				put_bit(0);
				put_bit(1);
				put_bit(0);
				break;
			case 'k':
				put_bit(1);
				put_bit(0);
				put_bit(0);
				put_bit(0);
				put_bit(0);
				put_bit(1);
				break;
			case 'K':
				put_bit(1);
				put_bit(0);
				put_bit(0);
				put_bit(0);
				put_bit(0);
				put_bit(0);
				break;
			}
		}
	}
		
	if (strcmp(ep_column, "-") != 0) {
		int epcn = ep_column[0] - 'a';

		if ((epcn > 0 && board[3*8 + epcn - 1] == 'P') ||
		    (epcn < 7 && board[3*8 + epcn + 1] == 'P')) {
			ep_any = 1;
		}
	}
	
	// really odd padding
	{
		int nb = 0, i;

		// find the right number of bits
		int right = (ep_any) ? 3 : 8;

		// castling needs four more
		if (strcmp(castling_rights, "-") != 0) {
			right = right + 4;
			if (right > 8)
				right %= 8;
		}

		if (bits_left > right)
			nb = bits_left - right;
		else if (bits_left < right)
			nb = bits_left + 8 - right;

		if (bits_left == 8 && strcmp(castling_rights, "-") == 0 && !ep_any)
			nb = 8;

		for (i = 0; i < nb; ++i) {
			put_bit(0);
		}
	}
	
	// en passant
	if (ep_any) {
		int epcn = ep_column[0] - 'a';

		put_bit(epcn & 0x04);
		put_bit(epcn & 0x02);
		put_bit(epcn & 0x01);
	}
	
	// castling rights
	if (strcmp(castling_rights, "-") != 0) {
		if (invert) {
			put_bit(strchr(castling_rights, 'K') != NULL);
			put_bit(strchr(castling_rights, 'Q') != NULL);
			put_bit(strchr(castling_rights, 'k') != NULL);
			put_bit(strchr(castling_rights, 'q') != NULL);
		} else {
			put_bit(strchr(castling_rights, 'k') != NULL);
			put_bit(strchr(castling_rights, 'q') != NULL);
			put_bit(strchr(castling_rights, 'K') != NULL);
			put_bit(strchr(castling_rights, 'Q') != NULL);
		}
	}

	// padding stuff
	if (bits_left == 8) {
		//++pos_len;
	} else {
#if 0
		++pos_len;
#else
		int i, nd = 8 - bits_left;
		for (i = 0; i < nd; ++i)
			put_bit(0);
#endif
	}
		
	// and the header byte
	position[0] = pos_len;

	if (strcmp(castling_rights, "-") != 0)
		position[0] |= 0x40;
	if (ep_any)
		position[0] |= 0x20;

#if DUMP_ENC
	{
		int i;
		for (i = 0; i < pos_len; ++i) {
			printf("%02x ", position[i]);
		}
		printf("\n");
	}
#endif
}
		
int search_pos(unsigned c, char *result)
{
	char buf[4];
	unsigned char pagebuf[4096];
	unsigned page;
	unsigned page_len;

	lseek(cto_fd, c * 4 + 16, SEEK_SET);
	
	read(cto_fd, buf, 4);
	page = htonl(*((unsigned *)buf));
	if (page == -1)
		return 0;

	lseek(ctg_fd, page * 4096 + 4096, SEEK_SET);
	read(ctg_fd, pagebuf, 4096);

	// search the page
	{
		int pos = 4;
		int page_end = htons(*((short *)(pagebuf + 2)));

		while (pos < page_end) {
			if (pagebuf[pos] != position[0] ||
			    memcmp(pagebuf + pos, position, pos_len) != 0) {
				// no match, skip through
				pos += pagebuf[pos] & 0x1f;
				pos += pagebuf[pos];
				pos += 33;
				continue;
			}
			pos += pagebuf[pos] & 0x1f;
			memcpy(result, pagebuf + pos, pagebuf[pos] + 33);
			return 1;
		}
	}

	return 0;
}

int lookup_position(char *pos, unsigned len, char *result)
{
	int hash = gen_hash(position, pos_len);
	int n;
	
	for (n = 0; n < 0x7fffffff; n = 2 * n + 1) {
		unsigned c = (hash & n) + n;

		// FIXME: adjust these bounds
		if (c < 0x80e0)
			continue;

		if (search_pos(c, result))
			return 1;
		
		if (c >= 0x1fd00)
			break;
	}

	return 0;
}

struct moveenc {
	char encoding;
	char piece;
	int num;
	int forward, right;
};
struct moveenc movetable[] = {
	0x00, 'P', 5,  1,  1,
	0x01, 'N', 2, -1, -2,
	0x03, 'Q', 2,  0,  2,
	0x04, 'P', 2,  1,  0,
	0x05, 'Q', 1,  1,  0,
	0x06, 'P', 4,  1, -1,
	0x08, 'Q', 2,  0,  4, 
	0x09, 'B', 2,  6,  6,
	0x0a, 'K', 1, -1,  0,
	0x0c, 'P', 1,  1, -1,
	0x0d, 'B', 1,  3,  3,
	0x0e, 'R', 2,  0,  3,
	0x0f, 'N', 1, -1, -2,
	0x12, 'B', 1,  7,  7,
	0x13, 'K', 1,  1,  0,
	0x14, 'P', 8,  1,  1,
	0x15, 'B', 1,  5,  5,
	0x18, 'P', 7,  1,  0,
	0x1a, 'Q', 2,  6,  0,
	0x1b, 'B', 1,  1, -1,
	0x1d, 'B', 2,  7,  7,
	0x21, 'R', 2,  0,  7,
	0x22, 'B', 2,  2, -2,
	0x23, 'Q', 2,  6,  6,
	0x24, 'P', 8,  1, -1,
	0x26, 'B', 1,  7, -7,
	0x27, 'P', 3,  1, -1,
	0x28, 'Q', 1,  5,  5,
	0x29, 'Q', 1,  0,  6,
	0x2a, 'N', 2, -2,  1,
	0x2d, 'P', 6,  1,  1,
	0x2e, 'B', 1,  1,  1,
	0x2f, 'Q', 1,  0,  1,
	0x30, 'N', 2, -2, -1,
	0x31, 'Q', 1,  0,  3,
	0x32, 'B', 2,  5,  5,
	0x34, 'N', 1,  2,  1,
	0x36, 'N', 1,  1,  2,
	0x37, 'Q', 1,  4,  0,
	0x38, 'Q', 2,  4, -4,
	0x39, 'Q', 1,  0,  5,
	0x3a, 'B', 1,  6,  6,
	0x3b, 'Q', 2,  5, -5,
	0x3c, 'B', 1,  5, -5,
	0x41, 'Q', 2,  5,  5,
	0x42, 'Q', 1,  7, -7,
	0x44, 'K', 1, -1,  1,
	0x45, 'Q', 1,  3,  3,
	0x4a, 'P', 8,  2,  0,
	0x4b, 'Q', 1,  5, -5,
	0x4c, 'N', 2,  2,  1,
	0x4d, 'Q', 2,  1,  0,
	0x50, 'R', 1,  6,  0,
	0x52, 'R', 1,  0,  6,
	0x54, 'B', 2,  1, -1,
	0x55, 'P', 3,  1,  0,
	0x5c, 'P', 7,  1,  1,
	0x5f, 'P', 5,  2,  0,
	0x61, 'Q', 1,  6,  6,
	0x62, 'P', 2,  2,  0,
	0x63, 'Q', 2,  7, -7,
	0x66, 'B', 1,  3, -3,
	0x67, 'K', 1,  1,  1,
	0x69, 'R', 2,  7,  0,
	0x6a, 'B', 1,  4,  4,
	0x6b, 'K', 1,  0,  2,   /* short castling */
	0x6e, 'R', 1,  0,  5,
	0x6f, 'Q', 2,  7,  7,
	0x72, 'B', 2,  7, -7,
	0x74, 'Q', 1,  0,  2,
	0x79, 'B', 2,  6, -6,
	0x7a, 'R', 1,  3,  0,
	0x7b, 'R', 2,  6,  0,
	0x7c, 'P', 3,  1,  1,
	0x7d, 'R', 2,  1,  0,
	0x7e, 'Q', 1,  3, -3,
	0x7f, 'R', 1,  0,  1,
	0x80, 'Q', 1,  6, -6,
	0x81, 'R', 1,  1,  0,
	0x82, 'P', 6,  1, -1,
	0x85, 'N', 1,  2, -1,
	0x86, 'R', 1,  0,  7,
	0x87, 'R', 1,  5,  0,
	0x8a, 'N', 1, -2,  1,
	0x8b, 'P', 1,  1,  1,
	0x8c, 'K', 1, -1, -1,
	0x8e, 'Q', 2,  2, -2,
	0x8f, 'Q', 1,  0,  7,
	0x92, 'Q', 2,  1,  1,
	0x94, 'Q', 1,  3,  0,
	0x96, 'P', 2,  1,  1,
	0x97, 'K', 1,  0, -1,
	0x98, 'R', 1,  0,  3,
	0x99, 'R', 1,  4,  0,
	0x9a, 'Q', 1,  6,  0,
	0x9b, 'P', 3,  2,  0,
	0x9d, 'Q', 1,  2,  0,
	0x9f, 'B', 2,  4, -4,
	0xa0, 'Q', 2,  3,  0,
	0xa2, 'Q', 1,  2,  2,
	0xa3, 'P', 8,  1,  0,
	0xa5, 'R', 2,  5,  0,
	0xa9, 'R', 2,  0,  2,
	0xab, 'Q', 2,  6, -6,
	0xad, 'R', 2,  0,  4,
	0xae, 'Q', 2,  3,  3,
	0xb0, 'Q', 2,  4,  0,
	0xb1, 'P', 6,  2,  0,
	0xb2, 'B', 1,  6, -6,
	0xb5, 'R', 2,  0,  5,
	0xb7, 'Q', 1,  5,  0,
	0xb9, 'B', 2,  3,  3,
	0xbb, 'P', 5,  1,  0,
	0xbc, 'Q', 2,  0,  5,
	0xbd, 'Q', 2,  2,  0,
	0xbe, 'K', 1,  0,  1,
	0xc1, 'B', 1,  2,  2,
	0xc2, 'B', 2,  2,  2,
	0xc3, 'B', 1,  2, -2,
	0xc4, 'R', 2,  0,  1,
	0xc5, 'R', 2,  4,  0,
	0xc6, 'Q', 2,  5,  0,
	0xc7, 'P', 7,  1, -1,
	0xc8, 'P', 7,  2,  0,
	0xc9, 'Q', 2,  7,  0,
	0xca, 'B', 2,  3, -3,
	0xcb, 'P', 6,  1,  0,
	0xcc, 'B', 2,  5, -5,
	0xcd, 'R', 1,  0,  2,
	0xcf, 'P', 4,  1,  0,
	0xd1, 'P', 2,  1, -1,
	0xd2, 'N', 2,  1,  2,
	0xd3, 'N', 2,  1, -2,
	0xd7, 'Q', 1,  1, -1,
	0xd8, 'R', 2,  0,  6,
	0xd9, 'Q', 1,  2, -2,
	0xda, 'N', 1, -2, -1,
	0xdb, 'P', 1,  2,  0,
	0xde, 'P', 5,  1, -1,
	0xdf, 'K', 1,  1, -1,
	0xe0, 'N', 2, -1,  2,
	0xe1, 'R', 1,  7,  0,
	0xe3, 'R', 2,  3,  0,
	0xe5, 'Q', 1,  0,  4,
	0xe6, 'P', 4,  2,  0,
	0xe7, 'Q', 1,  4,  4,
	0xe8, 'R', 1,  2,  0,
	0xe9, 'N', 1, -1,  2,
	0xeb, 'P', 4,  1,  1,
	0xec, 'P', 1,  1,  0,
	0xed, 'Q', 1,  7,  7,
	0xee, 'Q', 2,  1, -1,
	0xef, 'R', 1,  0,  4,
	0xf0, 'Q', 2,  0,  7,
	0xf1, 'Q', 1,  1,  1,
	0xf3, 'N', 2,  2, -1,
	0xf4, 'R', 2,  2,  0,
	0xf5, 'B', 2,  1,  1,
	0xf6, 'K', 1,  0, -2,   /* long castling */
	0xf7, 'N', 1,  1, -2,
	0xf8, 'Q', 2,  0,  1,
	0xf9, 'Q', 2,  6,  0,
	0xfa, 'Q', 2,  0,  3,
	0xfb, 'Q', 2,  2,  2,
	0xfd, 'Q', 1,  7,  0,
	0xfe, 'Q', 2,  3, -3
};

int find_piece(char *board, char piece, int num)
{
	int y, x;
	for (x = 0; x < 8; ++x) {
		for (y = 0; y < 8; ++y) {
			if (board[(7-y) * 8 + x] != piece)
				continue;
			if (--num == 0)
				return (y * 8 + x);
		}
	}

	fprintf(stderr, "Couldn't find piece '%c' number %u\n", piece, num);
	exit(1);
}

void execute_move(char *board, char *castling_rights, int inverted, char *ep_square, int from_square, int to_square)
{
	int black_ks, black_qs, white_ks, white_qs;

	// fudge
	from_square = (7 - (from_square / 8)) * 8 + (from_square % 8);
	to_square = (7 - (to_square / 8)) * 8 + (to_square % 8);

	// compute the new castling rights
	black_ks = (strchr(castling_rights, 'k') != NULL);
	black_qs = (strchr(castling_rights, 'q') != NULL);
	white_ks = (strchr(castling_rights, 'K') != NULL);
	white_qs = (strchr(castling_rights, 'Q') != NULL);

	if (board[from_square] == 'K') {
		if (inverted)
			black_ks = black_qs = 0;
		else
			white_ks = white_qs = 0;
	}
	if (board[from_square] == 'R') {
		if (inverted) {
			if (from_square == 56) // h1
				black_qs = 0;
			else if (from_square == 63) // h8
				black_ks = 0;
		} else {
			if (from_square == 56) // a1
				white_qs = 0;
			else if (from_square == 63) // a8
				white_ks = 0;
		}
	}
	if (board[to_square] == 'r') {
		if (inverted) {
			if (to_square == 0) // h1
				white_qs = 0;
			else if (to_square == 7) // h8
				white_ks = 0;
		} else {
			if (to_square == 0) // a1
				black_qs = 0;
			else if (to_square == 7) // a8
				black_ks = 0;
		}
	}

	if ((black_ks | black_qs | white_ks | white_qs) == 0) {
		strcpy(castling_rights, "-");
	} else {
		strcpy(castling_rights, "");

		if (white_ks)
			strcat(castling_rights, "K");
		if (white_qs)
			strcat(castling_rights, "Q");
		if (black_ks)
			strcat(castling_rights, "k");
		if (black_qs)
			strcat(castling_rights, "q");
	}

	// now the ep square
	if (board[from_square] == 'P' && to_square - from_square == -16) {
		sprintf(ep_square, "%c%u", "abcdefgh"[from_square % 8], from_square / 8);
	} else {
		strcpy(ep_square, "-");
	}

	// is this move an en passant capture?
	if (board[from_square] == 'P' && board[to_square] == ' ' &&
	    (to_square - from_square == -9 || to_square - from_square == -7)) {
	 	board[to_square + 8] = ' ';   	
	}

	// make the move
	board[to_square] = board[from_square];
	board[from_square] = ' ';

	// promotion
	if (board[to_square] == 'P' && to_square < 8)
		board[to_square] = 'Q';

	if (board[to_square] == 'K' && to_square - from_square == 2) {
		// short castling
		board[to_square - 1] = 'R';
		board[to_square + 1] = ' ';
	} else if (board[to_square] == 'K' && to_square - from_square == -2) {
		// long castling
		board[to_square + 1] = 'R';
		board[to_square - 2] = ' ';
	}

#if 0
	// dump the board
	{
		int y, x;
		printf("\n\n");
		for (y = 0; y < 8; ++y) {
			for (x = 0; x < 8; ++x) {
				putchar(board[y * 8 + x]);
			}
			putchar('\n');
		}
	}
	printf("cr='%s' ep='%s'\n", castling_rights, ep_square);
#endif
}

void dump_move(char *board, char *castling_rights, char *ep_col, int invert, int flip, char move, char annotation)
{
	int i;
	char newboard[64], nkr[5], neps[3];
	for (i = 0; i < sizeof(movetable)/sizeof(movetable[0]); ++i) {
		int from_square, from_row, from_col;
		int to_square, to_row, to_col;
		int ret;
		char result[256];

		if (move != movetable[i].encoding)
			continue;

		from_square = find_piece(board, movetable[i].piece, movetable[i].num);
		from_row = from_square / 8;
		from_col = from_square % 8;

		to_row = (from_row + 8 + movetable[i].forward) % 8;
		to_col = (from_col + 8 + movetable[i].right) % 8;
		to_square = to_row * 8 + to_col;
		
		// do the move, and look up the new position
		memcpy(newboard, board, 64);
		strcpy(nkr, castling_rights);
		execute_move(newboard, nkr, invert, neps, from_square, to_square);
		invert_board(newboard);
		
		if (needs_flipping(newboard, nkr)) {
			flip_board(newboard, neps);
			flip = !flip;
		}
		
		encode_position(newboard, !invert, nkr, neps);
		ret = lookup_position(position, pos_len, result);
		if (!ret) {
#if DUMP_FEN
			if (!invert) 
				invert_board(newboard);

			dump_fen(newboard, !invert, flip, nkr, neps);
#endif
			fprintf(stderr, "Destination move not found in book.\n");
			exit(1);
		}

#if DUMP_FEN
		// very useful for regression testing (some shell and
		// you can walk the entire book quite easily)
		if (!invert) 
			invert_board(newboard);
		dump_fen(newboard, !invert, flip, nkr, neps);
		return;
#endif

		// output the move
		{
			int fromcol = from_square % 8;
			int fromrow = from_square / 8;
			int tocol = to_square % 8;
			int torow = to_square / 8;

			if (invert) {
				fromrow = 7 - fromrow;
				torow = 7 - torow;
			}
			if (flip) {
				fromcol = 7 - fromcol;
				tocol = 7 - tocol;
			}

			printf("%c%u%c%u,",
				"abcdefgh"[fromcol], fromrow + 1,
				"abcdefgh"[tocol], torow + 1);
		}

		// annotation
		switch (annotation) {
		case 0x00:
			break;
		case 0x01:
			printf("!");
			break;
		case 0x02:
			printf("?");
			break;
		case 0x03:
			printf("!!");
			break;
		case 0x04:
			printf("??");
			break;
		case 0x05:
			printf("!?");
			break;
		case 0x06:
			printf("?!");
			break;
		case 0x08:
			printf(" (only move)");
			break;
		case 0x16:
			printf(" (zugzwang)");
			break;
		default:
			printf(" (unknown status 0x%02x)", annotation);
		}
		printf(",");

		output_stats(result, invert);
		return;
	}

	fprintf(stderr, "ERROR: Unknown move 0x%02x\n", move);
	exit(1);
}

void dump_info(char *board, char *castling_rights, char *ep_col, int invert, int flip, char *result)
{
	int book_moves = result[0] >> 1;
	int i;
	
#if !DUMP_FEN
	printf(",,");	
	output_stats(result, !invert);
#endif

	for (i = 0; i < book_moves; ++i) {
		dump_move(board, castling_rights, ep_col, invert, flip, result[i * 2 + 1], result[i * 2 + 2]);
	}
}

int main(int argc, char **argv)
{
	// encode the position
	char board[64], result[256];
	int invert = 0, flip;
	int ret;
	
	ctg_fd = open("RybkaII.ctg", O_RDONLY);
	cto_fd = open("RybkaII.cto", O_RDONLY);
	ctb_fd = open("RybkaII.ctb", O_RDONLY);
	decode_fen_board(argv[1], board);
	
	// always from white's position
	if (argv[2][0] == 'b') {
		invert = 1;
		invert_board(board);
	}
	
	// and the white king is always in the right half
	flip = needs_flipping(board, argv[3]);
	if (flip) {
		flip_board(board, argv[4]);
	}


#if 0
	// dump the board
	{
		int y, x;
		for (y = 0; y < 8; ++y) {
			for (x = 0; x < 8; ++x) {
				putchar(board[y * 8 + x]);
			}
			putchar('\n');
		}
	}
#endif

	encode_position(board, invert, argv[3], argv[4]);
	ret = lookup_position(position, pos_len, result);
	if (!ret) {
		//fprintf(stderr, "Not found in book.\n");
		exit(1);
	}

	dump_info(board, argv[3], argv[4], invert, flip, result);
	exit(0);
}

