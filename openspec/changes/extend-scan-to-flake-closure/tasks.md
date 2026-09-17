- [ ] 1. Derive (name,version) pairs from flake profile closures
      depends-on: none
      touches: tools/security-scan.sh
- [ ] 2. Add flake-derived names to scan set; keep manifest path
      depends-on: 1
      touches: tools/security-scan.sh, tools/cpe-map.json
- [ ] 3. Allow unmapped names to skip with warning instead of hard fail
      depends-on: 2
      touches: tools/security-scan.sh
- [ ] 4. Verify script completes and reports coverage gap
      depends-on: 3
      touches: .github/workflows/security-scan.yml
