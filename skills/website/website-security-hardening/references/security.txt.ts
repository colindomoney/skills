import type { APIRoute } from 'astro';

// RFC 9116 security.txt. Rendered per request so Expires rolls forward on
// its own and can never lapse, however long the site goes without a deploy.
export const prerender = false;

const CONTACT = 'mailto:security@colindomoney.com';
const CANONICAL = 'https://colindomoney.com/.well-known/security.txt';
const VALID_DAYS = 335; // about eleven months; RFC 9116 advises under a year

export const GET: APIRoute = () => {
  const expires = new Date();
  expires.setUTCHours(0, 0, 0, 0);
  expires.setUTCDate(expires.getUTCDate() + VALID_DAYS);

  const body = [
    `Contact: ${CONTACT}`,
    `Expires: ${expires.toISOString().replace('.000Z', 'Z')}`,
    'Preferred-Languages: en',
    `Canonical: ${CANONICAL}`,
    '',
  ].join('\n');

  return new Response(body, {
    status: 200,
    headers: {
      'content-type': 'text/plain; charset=utf-8',
      'cache-control': 'public, max-age=86400',
    },
  });
};
