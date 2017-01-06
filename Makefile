
all: src/main.d
	dmd -unittest -g $^ -of=drillease
