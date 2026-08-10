require 'xcodeproj'
project_path = 'PeriodontalCharting.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

def add_file_to_group(project, target, file_path, group_path)
  group = project.main_group.find_subpath(group_path, true)
  if group.nil?
    parts = group_path.split('/')
    parent = project.main_group
    parts.each do |part|
      child = parent.children.find { |c| c.display_name == part || c.path == part }
      if child.nil?
        child = parent.new_group(part)
        child.set_path(part)
        child.set_source_tree('<group>')
      end
      parent = child
    end
    group = parent
  end
  
  file_ref = group.new_reference(file_path)
  target.add_file_references([file_ref])
end

add_file_to_group(project, target, 'PeriodontalCharting/Models/Wav2Vec/Wav2Vec2_Indonesian_FP16.mlpackage', 'PeriodontalCharting/Models/Wav2Vec')
add_file_to_group(project, target, 'PeriodontalCharting/Models/Wav2Vec/vocab.json', 'PeriodontalCharting/Models/Wav2Vec')
add_file_to_group(project, target, 'PeriodontalCharting/Models/Wav2Vec/lexicon.txt', 'PeriodontalCharting/Models/Wav2Vec')
add_file_to_group(project, target, 'PeriodontalCharting/Models/Wav2Vec/canonical_mapping.json', 'PeriodontalCharting/Models/Wav2Vec')

add_file_to_group(project, target, 'PeriodontalCharting/Audio/Wav2Vec/PrefixTrie.swift', 'PeriodontalCharting/Audio/Wav2Vec')
add_file_to_group(project, target, 'PeriodontalCharting/Audio/Wav2Vec/CTCDecoder.swift', 'PeriodontalCharting/Audio/Wav2Vec')
add_file_to_group(project, target, 'PeriodontalCharting/Audio/Wav2Vec/Wav2VecAudioCapture.swift', 'PeriodontalCharting/Audio/Wav2Vec')
add_file_to_group(project, target, 'PeriodontalCharting/Audio/Wav2Vec/Wav2VecEngine.swift', 'PeriodontalCharting/Audio/Wav2Vec')
add_file_to_group(project, target, 'PeriodontalCharting/Audio/Wav2Vec/Wav2VecViewModel.swift', 'PeriodontalCharting/Audio/Wav2Vec')

project.save
