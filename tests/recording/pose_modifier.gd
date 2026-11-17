extends SkeletonModifier3D


func _process_modification_with_delta(_delta: float) -> void:
	get_skeleton().set_bone_pose_position(0, Vector3(0, 8, 0))
