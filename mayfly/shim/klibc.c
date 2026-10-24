/* Minimal freestanding string/memory helpers.
 * clang (unlike the aarch64-linux-gnu-gcc the upstream build used) does not
 * always inline __builtin_strcmp/memset/memcpy, so the shim needs its own.
 * Compiled with -fno-builtin to avoid the compiler rewriting these into
 * calls to themselves. */
#include <stddef.h>

int strcmp(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

void *memset(void *d, int c, size_t n)
{
	volatile unsigned char *p = d;

	while (n--)
		*p++ = (unsigned char)c;
	return d;
}

void *memcpy(void *d, const void *s, size_t n)
{
	volatile unsigned char *p = d;
	const volatile unsigned char *q = s;

	while (n--)
		*p++ = *q++;
	return d;
}
