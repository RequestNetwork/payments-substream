.PHONY: build
build:
	cargo build --locked --target wasm32-unknown-unknown --release

.PHONY: protogen
protogen:
	substreams protogen ./substreams.yaml --exclude-paths="sf/substreams,google"

.PHONY: sync-schema
sync-schema:
	cp ../schema.sql ./schema.sql

.PHONY: check-schema
check-schema:
	diff -q ../schema.sql schema.sql

.PHONY: package
package: sync-schema build
	substreams pack ./substreams.yaml

# Sepolia - uses Streamingfast Ethereum Sepolia endpoint; --network selects the networks: entry
.PHONY: gui
gui: build
	substreams gui ./substreams.yaml map_erc20_fee_proxy_payments -e sepolia.eth.streamingfast.io:443 --network sepolia

.PHONY: run
run: build
	substreams run ./substreams.yaml map_erc20_fee_proxy_payments -e sepolia.eth.streamingfast.io:443 --network sepolia --stop-block +100

.PHONY: clean
clean:
	cargo clean
	rm -f *.spkg

.PHONY: test
test:
	cargo test --locked

.PHONY: clippy
clippy:
	cargo clippy --locked --target wasm32-unknown-unknown -- -D warnings
