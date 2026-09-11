require "./spec_helper"

private def stage(name : Symbol) : TermBuf::Input::Stage
  TermBuf::Input::Stage.new name, ->(event : TermBuf::Input::Event, emit : Proc(TermBuf::Input::Event, Nil)) do
    emit.call event
  end
end

Spectator.describe TermBuf::Input::Stages do
  it "starts empty" do
    stages = TermBuf::Input::Stages.new
    expect(stages).to be_empty
    expect(stages.to_a).to eq [] of TermBuf::Input::Stage
  end

  it "keeps stages in the order they were pushed" do
    stages = TermBuf::Input::Stages.new
    stages.push(stage(:one)) << stage(:two)
    expect(stages.map(&.name)).to eq [:one, :two]
  end

  it "replaces the whole chain" do
    stages = TermBuf::Input::Stages.new
    stages.push stage(:old)
    stages.replace [stage(:new), stage(:newer)]
    expect(stages.map(&.name)).to eq [:new, :newer]
  end

  it "iterates over the chain as it was when the call began" do
    stages = TermBuf::Input::Stages.new
    stages.push stage(:first)

    seen = [] of Symbol
    stages.each do |current|
      seen << current.name
      stages.push stage(:added_meanwhile)
    end

    expect(seen).to eq [:first]
    expect(stages.map(&.name)).to eq [:first, :added_meanwhile]
  end

  it "keeps its own copy of what it was given" do
    stages = TermBuf::Input::Stages.new
    given = [stage(:given)]
    stages.replace given
    given.clear
    expect(stages.size).to eq 1
  end

  it "hands out an array nobody else holds" do
    stages = TermBuf::Input::Stages.new
    stages.push stage(:only)
    stages.to_a.clear
    expect(stages.size).to eq 1
  end

  it "loses nothing when many fibres push at once" do
    stages = TermBuf::Input::Stages.new
    done = Channel(Nil).new

    100.times do
      spawn do
        stages.push stage(:one_of_many)
        done.send nil
      end
    end

    100.times { done.receive }
    expect(stages.size).to eq 100
  end

  it "prints its names" do
    stages = TermBuf::Input::Stages.new
    stages.replace [stage(:resize), stage(:signals)]
    expect(stages.to_s).to eq "Stages(resize, signals)"
  end
end
