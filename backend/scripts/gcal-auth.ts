/**
 * One-off interactive OAuth helper. Run on a machine with a browser:
 *   cd backend && npm run gcal:auth
 * then copy the written token file to the homelab's data directory.
 *
 * The OAuth client MUST be type "Desktop app", and the consent screen's
 * publishing status MUST be "In production" — otherwise Google issues a
 * refresh token that expires every 7 days (spec §3.2).
 */
import { createServer } from 'node:http';
import { writeFileSync, chmodSync } from 'node:fs';
import { google, Auth } from 'googleapis';
import dotenv from 'dotenv';
import { DEFAULT_TOKEN_PATH, GCAL_SCOPE } from '../src/gcal-config.js';

dotenv.config();

const clientId = process.env.GOOGLE_OAUTH_CLIENT_ID;
const clientSecret = process.env.GOOGLE_OAUTH_CLIENT_SECRET;
const tokenPath = process.env.GOOGLE_OAUTH_TOKEN_PATH || DEFAULT_TOKEN_PATH;

if (!clientId || !clientSecret) {
  console.error('Set GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET in backend/.env first.');
  process.exit(1);
}

const server = createServer();
server.listen(0, '127.0.0.1', async () => {
  const address = server.address();
  if (typeof address === 'string' || address === null) throw new Error('no port');
  const redirectUri = `http://127.0.0.1:${address.port}`;

  const oauth2 = new google.auth.OAuth2(clientId, clientSecret, redirectUri);

  // PKCE (spec §6). The loopback redirect is a public client: any local
  // process can intercept the authorization code, so we must prove we hold the
  // matching code_verifier at exchange time. OAuth2 does NOT add PKCE
  // automatically — do not remove these two lines.
  const { codeVerifier, codeChallenge } = await oauth2.generateCodeVerifierAsync();
  if (!codeChallenge) {
    throw new Error('PKCE code_challenge generation failed');
  }
  const authUrl = oauth2.generateAuthUrl({
    access_type: 'offline',
    prompt: 'consent',
    scope: [GCAL_SCOPE],
    code_challenge: codeChallenge,
    code_challenge_method: Auth.CodeChallengeMethod.S256,
  });

  console.log('\n1. Open this URL and grant access:\n');
  console.log(authUrl + '\n');
  console.log('2. Google will redirect back to 127.0.0.1 automatically.\n');

  server.on('request', async (req, res) => {
    const url = new URL(req.url ?? '/', redirectUri);
    const code = url.searchParams.get('code');
    if (!code) {
      res.writeHead(400).end('No code in callback.');
      return;
    }
    try {
      const { tokens } = await oauth2.getToken({ code, codeVerifier });
      if (!tokens.refresh_token) {
        res.writeHead(500).end('No refresh token returned. Re-run with prompt=consent.');
        console.error('\nNo refresh token returned. Revoke prior access and re-run.');
        return;
      }
      writeFileSync(tokenPath, JSON.stringify(tokens, null, 2), 'utf8');
      chmodSync(tokenPath, 0o600);
      res.writeHead(200).end('Authorised. You can close this tab.');
      console.log(`\nToken written to ${tokenPath} (mode 600).`);
      console.log('Copy it to the homelab data directory and restart the container.\n');
    } catch (err) {
      res.writeHead(500).end('Token exchange failed.');
      console.error('\nToken exchange failed:', err);
    } finally {
      server.close();
    }
  });
});
