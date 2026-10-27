build:
    swift build

test:
    swift test

app:
    scripts/bundle.sh

run: app
    open GHView.app
