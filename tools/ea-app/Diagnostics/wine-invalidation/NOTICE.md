# Attribution and licensing

The Wine patch modifies `dlls/ntdll/unix/virtual.c`, whose existing header names
Alexandre Julliard and grants the GNU Lesser General Public License, version 2.1
or any later version. The patch preserves that file's existing notices.
`COPYING.LIB` is an unchanged copy of Wine's license text. The original Wine file
is identified by commit and SHA-256 in the report.

The original `translation-invalidation-matrix.c` was supplied by the external
mtld3d-x87 worker during this investigation. The unchanged source is retained in the adjacent `rosetta-feasibility` directory;
its SHA-256 is
`14fa91760a833f6af287388a6ae33ed5ed6425889b4824570d690130fced28d9`.
The range probe, cross-process probe, controlled API tests and portable runner
were prepared by the collaborating NFS 2015 compatibility investigation.

No standalone license declaration accompanied the original probe sources.
This bundle preserves their attribution and does not invent an additional
license grant on the original worker's behalf. The Wine license text above
describes the Wine-derived patch; it is not presented as a verified original
license declaration for every independent test source.
